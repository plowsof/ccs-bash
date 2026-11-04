// Package gate: which of a push's files may go live (ccs-receive's verdict). Each file staging
// holds that isn't the live site's, byte for byte, and each page and JSON file to check again (all
// of them, or the held-back ones), needs the checks its name calls for, and goes live only if
// every one of them passed it: a check that didn't run, didn't finish or didn't get to it holds
// the file back, as one that failed it does. Nothing goes live for want of a complaint.
package gate

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha1"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"hash"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"

	"ccs-check/push"
	"ccs-check/scan"
)

// Config: where everything is (ccs-receive's names)
type Config struct {
	Staging, Live string
	// the signed list (its .qr.sha256 beside it), the allowed file, the design's sums
	List, Allowed, DesignSums string
	// ccs-check pages' DESIGNS BODIES VIEWKEY HOSTS ONION FRONTS ("" designs: no release)
	Designs, Bodies, Viewkey, Hosts, Onion, Fronts string
	// the proposals repository's images, "blob path" a line (git ls-tree); "" if not fetched
	Images string
	// the feed's checker (feed.awk) and the site its links must be under (SITE_URL)
	FeedAwk, Site string
	// the files held back last time (one a line, relative); every page and JSON file if Full
	Held string
	Full bool
	// this program: ccs-check pages runs as its own process (its time and memory limits)
	Self string
}

var (
	qrName = regexp.MustCompile(`^qr/[1-9A-HJ-NP-Za-km-z]{95}\.png$`)
	image  = regexp.MustCompile(`^images/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+\.(png|jpg|jpeg|gif)$`)
	sumRx  = regexp.MustCompile(`^([0-9a-f]{64}) [ *](\./)?(.+)$`)
	siteRx = regexp.MustCompile(`^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?$`)
	listed = map[string]bool{"subaddresses.txt": true, "subaddresses.txt.asc": true, "subaddresses.txt.key.asc": true}
)

// a file's verdict: the checks it needs, those that passed it, and why not
type verdict struct {
	need, passed map[string]bool
	why          []string
}

type run struct {
	c  Config
	v  map[string]*verdict // by path in staging
	ok map[string]bool     // the list's addresses and the allowed ones
}

func (r *run) needs(p string, checks ...string) {
	if r.v[p] == nil {
		r.v[p] = &verdict{need: map[string]bool{}, passed: map[string]bool{}}
	}
	for _, c := range checks {
		r.v[p].need[c] = true
	}
}

// done: check passed p, or (why) didn't
func (r *run) done(p, check, why string) {
	if why == "" {
		r.v[p].passed[check] = true
	} else {
		r.v[p].why = append(r.v[p].why, why)
	}
}

// Run: the files that don't go live, as ccs-receive's lines: "file<TAB>!reason", or
// "file<TAB>address" for an address that is neither the list's nor allowed (file: its path in
// staging), sorted, each once; and how many pages and JSON files it checked, of how many
func Run(c Config, w io.Writer) (int, int, error) {
	r := &run{c: c, v: map[string]*verdict{}}
	var err error
	if r.ok, err = addresses(c.List, c.Allowed); err != nil {
		return 0, 0, err
	}
	held := map[string]bool{}
	if b, err := os.ReadFile(c.Held); err == nil {
		for _, l := range strings.Split(string(b), "\n") {
			held[l] = l != ""
		}
	}
	var texts []string
	total := 0
	err = filepath.WalkDir(c.Staging, func(p string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return err
		}
		rel, _ := filepath.Rel(c.Staging, p)
		if !d.Type().IsRegular() {
			// (ccs-check receive and copy make none)
			return errors.New(rel + ": not a plain file or folder")
		}
		changed := !push.Same(p, filepath.Join(c.Live, rel))
		if strings.HasSuffix(rel, ".html") || strings.HasSuffix(rel, ".json") || rel == "feed.xml" {
			total++
			if c.Full || changed || held[rel] {
				texts = append(texts, p)
				r.needs(p, "scan")
				if strings.HasSuffix(rel, ".html") || rel == "projects.json" {
					r.needs(p, "pages")
				}
			}
		}
		switch {
		case !changed, strings.HasSuffix(rel, ".html"), rel == "projects.json":
			// (live already, or its checks above)
		case rel == "feed.xml":
			r.needs(p, "feed")
		case listed[rel]:
			r.needs(p, "file")
		case strings.HasPrefix(rel, "qr/"):
			r.needs(p, "qr")
		case strings.HasPrefix(rel, "images/") && strings.Count(rel, "/") >= 2:
			r.needs(p, "image")
		default:
			r.needs(p, "design")
		}
		return nil
	})
	if err != nil {
		return 0, 0, err
	}
	sort.Strings(texts)
	if err := r.files(); err != nil {
		return 0, 0, err
	}
	r.scans(texts)
	r.pages(texts)
	r.feed()
	// each file goes live only with every check it needs passed
	var out []string
	for p, v := range r.v {
		for _, why := range v.why {
			out = append(out, p+"\t"+why)
		}
		for c := range v.need {
			if !v.passed[c] && len(v.why) == 0 {
				out = append(out, p+"\t!a file the gate could not check ("+c+")")
				break
			}
		}
	}
	sort.Strings(out)
	bw := bufio.NewWriter(w)
	for i, l := range out {
		if i == 0 || l != out[i-1] {
			fmt.Fprintln(bw, l)
		}
	}
	return len(texts), total, bw.Flush()
}

// addresses: the list's (each line's second word) and the allowed file's (each line's first, # a
// comment); none in the list is an error: then nothing could be held for an address
func addresses(list, allowed string) (map[string]bool, error) {
	ok := map[string]bool{}
	b, err := os.ReadFile(list)
	if err != nil {
		return nil, err
	}
	for _, l := range strings.Split(string(b), "\n") {
		if f := strings.Fields(l); len(f) >= 2 {
			ok[f[1]] = true
		}
	}
	if len(ok) == 0 {
		return nil, errors.New("the list has no addresses")
	}
	b, _ = os.ReadFile(allowed)
	for _, l := range strings.Split(string(b), "\n") {
		if f := strings.Fields(l); len(f) >= 1 && !strings.HasPrefix(f[0], "#") {
			ok[f[0]] = true
		}
	}
	return ok, nil
}

// files: the checks made by a file's bytes: the design's, the list's QR codes, the repository's
// images, the list's own files
func (r *run) files() error {
	design, err := sums(r.c.DesignSums)
	if err != nil {
		return err
	}
	qrs, err := sums(r.c.List + ".qr.sha256")
	if err != nil {
		return err
	}
	var imgs map[string]bool
	if r.c.Images != "" {
		b, err := os.ReadFile(r.c.Images)
		if err != nil {
			return err
		}
		imgs = map[string]bool{}
		for _, l := range strings.Split(string(b), "\n") {
			imgs[l] = l != ""
		}
	}
	for p, v := range r.v {
		rel, _ := filepath.Rel(r.c.Staging, p)
		switch why := ""; {
		case v.need["design"]:
			if !design[sum(p, sha256.New(), "")+" "+rel] {
				why = "!not the design's (design.sha256)"
			}
			r.done(p, "design", why)
		case v.need["qr"]:
			if !qrName.MatchString(rel) {
				why = "!not a QR code of the list's (qr/<address>.png)"
			} else if !qrs[sum(p, sha256.New(), "")+" "+strings.TrimPrefix(rel, "qr/")] {
				why = "!not the signed list's QR code of that address (its .qr.sha256)"
			}
			r.done(p, "qr", why)
		case v.need["image"]:
			if !image.MatchString(rel) {
				why = "!not a proposal image (images/<proposal>/<file>.png|jpg|jpeg|gif)"
			} else if imgs == nil {
				why = "!a new image, and the proposals repository could not be read to check it"
			} else if st, err := os.Stat(p); err != nil || !imgs[sum(p, sha1.New(), fmt.Sprintf("blob %d\x00", st.Size()))+" "+rel] {
				// (git's blob id: git hash-object --no-filters)
				why = "!not the proposals repository's " + rel
			}
			r.done(p, "image", why)
		case v.need["file"]:
			if !push.Same(p, filepath.Join(filepath.Dir(r.c.List), rel)) {
				why = "!not the " + rel + " installed in " + filepath.Dir(r.c.List)
			}
			r.done(p, "file", why)
		}
	}
	return nil
}

// sums: a sha256sum file's "sum path" pairs (./ and the binary-mode * dropped)
func sums(f string) (map[string]bool, error) {
	b, err := os.ReadFile(f)
	if err != nil {
		return nil, err
	}
	m := map[string]bool{}
	for _, l := range strings.Split(string(b), "\n") {
		if x := sumRx.FindStringSubmatch(l); x != nil {
			m[x[1]+" "+x[3]] = true
		}
	}
	return m, nil
}

// sum: h of head and then the file's bytes, as hex ("" if it can't be read)
func sum(p string, h hash.Hash, head string) string {
	f, err := os.Open(p)
	if err != nil {
		return ""
	}
	defer f.Close()
	io.WriteString(h, head)
	if _, err := io.Copy(h, f); err != nil {
		return ""
	}
	return hex.EncodeToString(h.Sum(nil))
}

// scans: ccs-check nul, json and scan over the pages and JSON to check: a file passes only if they
// read it, with nothing against it; an address only if the list's or allowed (the feed's: none)
func (r *run) scans(texts []string) {
	var jsons []string
	for _, p := range texts {
		if strings.HasSuffix(p, ".json") {
			jsons = append(jsons, p)
		}
	}
	var b, nul bytes.Buffer
	err := errors.Join(scan.NUL(texts, &nul), scan.JSON(jsons, &b), scan.Pages(texts, &b))
	found := lines(b.Bytes())
	for _, f := range strings.Fields(nul.String()) {
		found[f] = append(found[f], "!a NUL byte (a browser drops it from the text)")
	}
	feed := filepath.Join(r.c.Staging, "feed.xml")
	for _, p := range texts {
		if err != nil {
			r.done(p, "scan", "!its addresses could not be read ("+err.Error()+")")
			continue
		}
		bad := false
		for _, t := range found[p] {
			why := t
			switch {
			case strings.HasPrefix(t, "?qr"):
				why = "!a data: image (the site has none: its QR codes are files, qr/<address>.png)"
			case strings.HasPrefix(t, "!"):
			case p == feed:
				why = "!an address in the feed, which never has one (" + t[:min(12, len(t))] + "…)"
			case r.ok[t]:
				continue
			}
			r.done(p, "scan", why)
			bad = true
		}
		if !bad {
			r.done(p, "scan", "")
		}
	}
}

// lines: "file<TAB>rest" lines, by file
func lines(out []byte) map[string][]string {
	m := map[string][]string{}
	for _, l := range strings.Split(string(out), "\n") {
		if f, rest, ok := strings.Cut(l, "\t"); ok {
			m[f] = append(m[f], rest)
		}
	}
	return m
}

// command: prog args, stdin in, within d; its stdout, and whether it finished well
func command(d time.Duration, in []byte, prog string, args ...string) ([]byte, bool) {
	ctx, cancel := context.WithTimeout(context.Background(), d)
	defer cancel()
	cmd := exec.CommandContext(ctx, prog, args...)
	cmd.Stdin = bytes.NewReader(in)
	cmd.Env = append(os.Environ(), "LC_ALL=C")
	out, err := cmd.Output()
	return out, err == nil
}

// pages: ccs-check pages over the pages (and projects.json) to check, 5 minutes at most: each
// passes only with its "=ok"
func (r *run) pages(texts []string) {
	var list []string
	var in bytes.Buffer
	for _, p := range texts {
		if r.v[p].need["pages"] {
			rel, _ := filepath.Rel(r.c.Staging, p)
			list = append(list, p)
			in.WriteString(rel + "\x00")
		}
	}
	if len(list) == 0 {
		return
	}
	var got map[string][]string
	if r.c.Designs != "" {
		out, _ := command(5*time.Minute, in.Bytes(), r.c.Self, "pages", r.c.Staging, r.c.Designs, r.c.Bodies,
			r.c.List, r.c.Viewkey, r.c.Hosts, r.c.Onion, r.c.Fronts, r.c.Live)
		got = lines(out)
	}
	for _, p := range list {
		switch ts := got[p]; {
		case r.c.Designs == "":
			r.done(p, "pages", "!no design release (design/vX.Y.Z/) to check it against")
		case len(ts) == 0:
			r.done(p, "pages", "!a page the gate could not check (in time)")
		default:
			for _, t := range ts {
				if t != "=ok" {
					r.done(p, "pages", t)
				}
			}
			if len(r.v[p].why) == 0 {
				r.done(p, "pages", "")
			}
		}
	}
}

// feed: feed.xml as feed.awk checks it (a minute at most), its links this site's (SITE_URL:
// without one, no feed passes), each to a proposal page in the push or live
func (r *run) feed() {
	p := filepath.Join(r.c.Staging, "feed.xml")
	if v := r.v[p]; v == nil || !v.need["feed"] {
		return
	}
	site := strings.TrimSuffix(r.c.Site, "/")
	b, err := os.ReadFile(p)
	switch {
	case !siteRx.MatchString(site):
		r.done(p, "feed", "!a feed, and no SITE_URL (https://host) in alert.conf for its links")
		return
	case err != nil || len(b) > 500000 || len(b) == 0 || b[len(b)-1] != '\n':
		r.done(p, "feed", "!not the feed (over 500 kB, or no newline at its end)")
		return
	}
	out, ok := command(time.Minute, b, "awk", "-v", "site="+site, "-f", r.c.FeedAwk)
	if !ok {
		why := strings.TrimSpace(string(out))
		if why == "" {
			why = "the feed could not be checked"
		}
		r.done(p, "feed", "!"+why)
		return
	}
	for _, name := range strings.Split(strings.TrimSuffix(string(out), "\n"), "\n") {
		page := filepath.Join("proposals", name+".html")
		if name != "" && !isFile(filepath.Join(r.c.Staging, page)) && !isFile(filepath.Join(r.c.Live, page)) {
			r.done(p, "feed", "!a link to no proposal page of this site ("+name+")")
			return
		}
	}
	r.done(p, "feed", "")
}

func isFile(p string) bool {
	st, err := os.Stat(p)
	return err == nil && st.Mode().IsRegular()
}

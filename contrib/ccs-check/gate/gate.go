// Package gate: which files of the site the web server built may go live (ccs-receive's
// verdict). Its pages, JSON and feed are scanned for addresses (each the signed list's or allowed;
// the feed's none), NUL bytes and data: images; its QR codes must be the signed list's, by their
// sums. A file that can't be read for it fails, as one with something against it does.
package gate

import (
	"bufio"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	"ccs-check/scan"
)

// Config: where everything is (ccs-receive's names)
type Config struct {
	// the site built, the signed list (its .qr.sha256 beside it), the allowed file
	Site, List, Allowed string
}

var (
	qrName = regexp.MustCompile(`^qr/[1-9A-HJ-NP-Za-km-z]{95}\.png$`)
	sumRx  = regexp.MustCompile(`^([0-9a-f]{64}) [ *](\./)?(.+)$`)
)

// Run: the files that may not go live, as ccs-receive's lines: "file<TAB>!reason", or
// "file<TAB>address" for an address that is neither the list's nor allowed (file: its path in
// Site), sorted, each once; and how many files it read
func Run(c Config, w io.Writer) (int, error) {
	ok, err := addresses(c.List, c.Allowed)
	if err != nil {
		return 0, err
	}
	qrs, err := sums(c.List + ".qr.sha256")
	if err != nil {
		return 0, err
	}
	var texts, out []string
	n := 0
	err = filepath.WalkDir(c.Site, func(p string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return err
		}
		n++
		rel, _ := filepath.Rel(c.Site, p)
		switch {
		case !d.Type().IsRegular():
			out = append(out, p+"\t!not a plain file")
		case strings.HasSuffix(rel, ".html") || strings.HasSuffix(rel, ".json") || rel == "feed.xml":
			texts = append(texts, p)
		case strings.HasPrefix(rel, "qr/"):
			if !qrName.MatchString(rel) {
				out = append(out, p+"\t!not a QR code of the list's (qr/<address>.png)")
			} else if !qrs[sum(p)+" "+strings.TrimPrefix(rel, "qr/")] {
				out = append(out, p+"\t!not the signed list's QR code of that address (its .qr.sha256)")
			}
		}
		return nil
	})
	if err != nil {
		return 0, err
	}
	out = append(out, scans(texts, ok, filepath.Join(c.Site, "feed.xml"))...)
	sort.Strings(out)
	bw := bufio.NewWriter(w)
	for i, l := range out {
		if i == 0 || l != out[i-1] {
			fmt.Fprintln(bw, l)
		}
	}
	return n, bw.Flush()
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

// sum: the file's sha256, as hex ("" if it can't be read)
func sum(p string) string {
	f, err := os.Open(p)
	if err != nil {
		return ""
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return ""
	}
	return hex.EncodeToString(h.Sum(nil))
}

// scans: ccs-check nul, json and scan over the pages, JSON and feed: a file passes only if they
// read it, with nothing against it; an address only if the list's or allowed (the feed's: none)
func scans(texts []string, ok map[string]bool, feed string) []string {
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
	var out []string
	for _, p := range texts {
		if err != nil {
			out = append(out, p+"\t!its addresses could not be read ("+err.Error()+")")
			continue
		}
		for _, t := range found[p] {
			why := t
			switch {
			case strings.HasPrefix(t, "?qr"):
				why = "!a data: image (the site has none: its QR codes are files, qr/<address>.png)"
			case strings.HasPrefix(t, "!"):
			case p == feed:
				why = "!an address in the feed, which never has one (" + t[:min(12, len(t))] + "…)"
			case ok[t]:
				continue
			}
			out = append(out, p+"\t"+why)
		}
	}
	return out
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

// Package sitedata checks site-data.json, the backend's whole push.
//
// It holds what only the backend knows: each proposal's subaddress index, dates and funds, and
// the ideas. (The web server reads the front matter and MR links from the proposals repository
// itself.)
//
// The web server builds the site (ccs-gate-build) from the version Clean re-writes, never from
// the pushed bytes. The rules:
//   - every key appears once, spelled exactly as ccs-bash writes it, and no other keys;
//   - each value has the right type;
//   - an index is on the signed list, is never 0 (the wallet's main address), and is not shared
//     by two proposals;
//   - a proposal the live site already gave an address (the gate's pins, its projects.json)
//     keeps that address, whatever the push says;
//   - amounts are formatted as ccs-bash's xmr4 writes them;
//   - an idea's name and author are plain text with no address in them, and its link is an MR
//     of the proposals repository.
package sitedata

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"ccs-check/addr"
)

type stateEntry struct {
	GitlabURL           *string `json:"gitlab_url"`
	SubaddrIndex        *int64  `json:"subaddr_index"`
	FundingRequiredDate *string `json:"funding_required_date"`
	FundedDate          *string `json:"funded_date"`
}

type fundEntry struct {
	Amount     *string      `json:"amount"`
	Raised     *string      `json:"raised"`
	Pending    *json.Number `json:"pending"`
	Count      *int64       `json:"count"`
	Percentage *int64       `json:"percentage"`
	Needed     *string      `json:"needed"`
}

type ideaEntry struct {
	Name      *string `json:"name"`
	GitlabURL *string `json:"gitlab-url"`
	Author    *string `json:"author"`
	Date      *string `json:"date"`
	CreatedAt *string `json:"created-at,omitempty"`
	Upvotes   *int64  `json:"upvotes"`
	Downvotes *int64  `json:"downvotes"`
}

type siteData struct {
	State map[string]*stateEntry `json:"state"`
	Funds map[string]*fundEntry  `json:"funds"`
	Ideas []*ideaEntry           `json:"ideas"`
}

// shape describes what may appear at each place in site-data.json, so keys can be checked exactly
type shape struct {
	fields map[string]*shape // an object of these keys (each nil: a value, no object or array)
	each   *shape            // an object of any keys (file.md), or an array: each of its values
}

func names(ks ...string) *shape {
	m := map[string]*shape{}
	for _, k := range ks {
		m[k] = nil
	}
	return &shape{fields: m}
}

// The keys as ccs-bash writes them (siteData's json tags)
var dataShape = &shape{fields: map[string]*shape{
	"state": {each: names("gitlab_url", "subaddr_index", "funding_required_date", "funded_date")},
	"funds": {each: names("amount", "raised", "pending", "count", "percentage", "needed")},
	"ideas": {each: names("name", "gitlab-url", "author", "date", "created-at", "upvotes", "downvotes")},
}}

// exact checks that the next value dec reads has each key once, spelled exactly as s names it.
// Go's decoder accepts "STATE" or "Subaddr_Index" for "state" or "subaddr_index", and takes the
// last of a duplicate key. jq, which builds the site, reads only the exact key. Without this
// check, one site-data.json could mean two different things. Value types are checked by Decode.
func exact(dec *json.Decoder, s *shape) error {
	t, err := dec.Token()
	if err != nil {
		return err
	}
	d, ok := t.(json.Delim)
	if !ok {
		return nil
	}
	if s == nil || s.fields == nil && s.each == nil {
		return errors.New("an object or array where a value goes")
	}
	if d == '[' {
		if s.each == nil {
			return errors.New("an array where an object goes")
		}
		for dec.More() {
			if err := exact(dec, s.each); err != nil {
				return err
			}
		}
		_, err = dec.Token()
		return err
	}
	seen := map[string]bool{}
	for dec.More() {
		t, err := dec.Token()
		if err != nil {
			return err
		}
		k, _ := t.(string)
		if seen[k] {
			return fmt.Errorf("the key %.40q twice", k)
		}
		seen[k] = true
		sub := s.each
		if s.fields != nil {
			if sub, ok = s.fields[k]; !ok {
				return fmt.Errorf("the key %.40q", k)
			}
		}
		if err := exact(dec, sub); err != nil {
			return err
		}
	}
	_, err = dec.Token()
	return err
}

// Max is the largest site-data.json read (the real one, 316 proposals, is about 100 kB)
const Max = 4 << 20

var (
	xmr4Rx    = regexp.MustCompile(`^[0-9]{1,7}\.[0-9]{4}$`)
	pendingRx = regexp.MustCompile(`^[0-9]{1,7}(\.[0-9]{1,4})?$`)
	utcRx     = regexp.MustCompile(`^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$`)
	// An idea's date, as ccs-bash writes it ("October 1, 2026"), or none
	dateRx = regexp.MustCompile(`^((January|February|March|April|May|June|July|August|September|October|November|December) [1-9][0-9]?, [0-9]{4})?$`)
	ents   = []string{"&amp;", "&lt;", "&gt;", "&quot;", "&#39;", "&apos;"}
)

// Checker holds what site-data.json is checked against
type Checker struct {
	index     map[string]string // the signed list's addresses, by index
	proposals map[string]bool   // the proposals (file.md) in the repository's commits fetched
	pins      map[string]string // the address the live site has given each proposal (file.md), the list's
	link      *regexp.Regexp    // a merge request of the proposals repository
}

// New builds a Checker from:
//   - the signed list ("index address" lines);
//   - the proposals in the repository (a file of names, file.md, one per line);
//   - HOSTS, where the repository is (host/path, space-separated);
//   - the live site's projects.json, with the addresses its proposals have ("" for none);
//   - PINS, the gate's own record ("file.md address" lines), kept from when each proposal first
//     had its address. A push that hides a proposal from projects.json can't release its
//     address. PINS wins over projects.json. "" or a missing file means none.
func New(list, proposals, hosts, live, pins string) (*Checker, error) {
	c := &Checker{index: map[string]string{}, proposals: map[string]bool{}, pins: map[string]string{}}
	b, err := os.ReadFile(list)
	if err != nil {
		return nil, err
	}
	listed := map[string]bool{}
	for _, l := range strings.Split(string(b), "\n") {
		if f := strings.Fields(l); len(f) >= 2 {
			c.index[f[0]] = f[1]
			listed[f[1]] = true
		}
	}
	if len(c.index) == 0 {
		return nil, errors.New("the list has no addresses")
	}
	if b, err = os.ReadFile(proposals); err != nil {
		return nil, err
	}
	for _, l := range strings.Split(string(b), "\n") {
		c.proposals[l] = strings.HasSuffix(l, ".md")
	}
	var hs []string
	for _, h := range strings.Fields(hosts) {
		hs = append(hs, regexp.QuoteMeta(strings.Trim(h, "/")))
	}
	if len(hs) == 0 {
		hs = []string{`\b\B`} // (no host: no link passes)
	}
	c.link = regexp.MustCompile(`^https://(` + strings.Join(hs, "|") + `)(/-/merge_requests/|/merge_requests/|/pulls/)[0-9]{1,10}$`)
	if pins != "" {
		b, err := os.ReadFile(pins)
		if err != nil && !errors.Is(err, os.ErrNotExist) {
			return nil, err
		}
		// The address is after the last space: a proposal's name can have spaces in it
		for _, l := range strings.Split(string(b), "\n") {
			if i := strings.LastIndexByte(l, ' '); i > 0 && listed[l[i+1:]] && c.pins[l[:i]] == "" {
				c.pins[l[:i]] = l[i+1:]
			}
		}
	}
	if live != "" {
		for f, a := range addresses(live) {
			if listed[a] && c.pins[f] == "" {
				c.pins[f] = a
			}
		}
	}
	return c, nil
}

// addresses returns each proposal's address (by filename) from the projects.json in dir, as the
// gate built it. None if it can't be read; then every proposal is new to the site.
func addresses(dir string) map[string]string {
	m := map[string]string{}
	b, err := os.ReadFile(dir + "/projects.json")
	if err != nil || len(b) > Max {
		return m
	}
	var ps []struct{ Filename, Address *string }
	if json.Unmarshal(b, &ps) != nil {
		return m
	}
	for _, p := range ps {
		if p.Filename != nil && p.Address != nil {
			m[*p.Filename] = *p.Address
		}
	}
	return m
}

// q quotes a proposal's name for a reason: the backend chose it, and the reason is logged and
// sent to IRC
func q(s string) string { return strconv.QuoteToASCII(s) }

// utc reports whether s is a UTC time as ccs-bash writes them (2026-10-01T12:34:56Z): a real date
// and time, which jq's fromdate reads, and not over a day ahead (a date far ahead would keep an
// idea first in the feed for good).
func utc(s string) bool {
	t, err := time.Parse("2006-01-02T15:04:05Z", s)
	return utcRx.MatchString(s) && err == nil && t.Before(time.Now().Add(24*time.Hour))
}

// text checks an idea's name or author, escaped as ccs-bash writes it (jq @html): printable
// ASCII only (anyone can open an MR: no letter of another script can stand in for an address's,
// and nothing shows in another order), no markup, at most 1000 characters (an entity counts as
// one), and no run of 90 characters that could be an address.
func text(s string) bool {
	if !utf8.ValidString(s) {
		return false
	}
	n, run := 0, 0
	for i := 0; i < len(s); n++ {
		r, w := utf8.DecodeRuneInString(s[i:])
		if r == '&' {
			w = 0
			for _, e := range ents {
				if strings.HasPrefix(s[i:], e) {
					w = len(e)
				}
			}
			if w == 0 {
				return false
			}
		} else if strings.ContainsRune("<>\"'", r) || r <= 0x1f || r >= 0x7f {
			return false
		}
		if w == 1 {
			if isRun(r) {
				run++
			} else {
				run = 0
			}
		} else {
			run = 0 // (an entity: & and ; are neither)
		}
		if run >= 90 || n >= 1000 {
			return false
		}
		i += w
	}
	return true
}

// A character of an address
func isRun(r rune) bool {
	return r >= '1' && r <= '9' || r >= 'A' && r <= 'Z' && r != 'I' && r != 'O' || r >= 'a' && r <= 'z' && r != 'l'
}

// address reports whether s (an idea's name or author, ASCII: text) contains an address, read
// the way the gate's scan reads the site's JSON: whole, or in groups.
func address(s string) bool {
	c, out := addr.New(), map[string]bool{}
	c.Start()
	return c.Runs(s, out) != nil || len(out) > 0
}

// read parses b as siteData strictly: valid UTF-8, each key once and spelled exactly as
// ccs-bash writes it, no unknown keys, nothing after it.
func read(b []byte) (*siteData, error) {
	if !utf8.Valid(b) {
		return nil, errors.New("not UTF-8")
	}
	dec := json.NewDecoder(bytes.NewReader(b))
	dec.UseNumber()
	if err := exact(dec, dataShape); err != nil {
		return nil, err
	}
	dec = json.NewDecoder(bytes.NewReader(b))
	dec.DisallowUnknownFields()
	dec.UseNumber()
	var d siteData
	if err := dec.Decode(&d); err != nil {
		return nil, err
	}
	if _, err := dec.Token(); err != io.EOF {
		return nil, errors.New("something after it")
	}
	if d.State == nil || d.Funds == nil || d.Ideas == nil {
		return nil, errors.New("no state, funds or ideas")
	}
	return &d, nil
}

// Check returns "" if site-data.json (bytes b) passes, else the reason it fails.
func (c *Checker) Check(b []byte) string {
	_, why := c.Clean(b)
	return why
}

// Clean returns site-data.json (bytes b) as Check parsed it, written again (each key once, as
// ccs-bash writes it, nothing else), or the reason it fails. The site is built from this, never
// from b itself.
func (c *Checker) Clean(b []byte) ([]byte, string) {
	if len(b) > Max {
		return nil, "a site-data.json over 4 MB"
	}
	d, err := read(b)
	if err != nil {
		return nil, "a site-data.json that isn't as ccs-bash writes it (" + err.Error() + ")"
	}
	if why := c.check(d); why != "" {
		return nil, why
	}
	var out bytes.Buffer
	enc := json.NewEncoder(&out)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "    ")
	if err := enc.Encode(d); err != nil {
		return nil, "site-data.json can't be written again (" + err.Error() + ")"
	}
	return out.Bytes(), ""
}

func (c *Checker) check(d *siteData) string {
	owners := map[string]string{}
	for f, s := range d.State {
		switch {
		case !c.proposals[f]:
			return q(f) + ": no proposal in the proposals repository"
		case s == nil:
			return q(f) + ": no state"
		case s.GitlabURL != nil && !c.link.MatchString(*s.GitlabURL):
			return q(f) + ": a link that isn't a merge request of the proposals repository"
		case s.FundingRequiredDate != nil && !utc(*s.FundingRequiredDate),
			s.FundedDate != nil && !utc(*s.FundedDate):
			return q(f) + ": a date that isn't one (UTC, as ccs-bash writes them)"
		}
		if s.SubaddrIndex == nil {
			if c.pins[f] != "" {
				return q(f) + ": no subaddress, where the live site has given it one (the gate's pins)"
			}
			continue
		}
		a, ok := c.index[strconv.FormatInt(*s.SubaddrIndex, 10)]
		switch {
		case *s.SubaddrIndex <= 0 || !ok:
			return q(f) + ": a subaddress index the signed list hasn't (or the wallet's main address)"
		case owners[a] != "":
			return q(f) + ": the subaddress " + q(owners[a]) + " has"
		}
		owners[a] = f
		if p, pin := c.pins[f]; pin && p != a {
			return q(f) + ": another subaddress than the live site has for it"
		}
	}
	// A pin for a proposal no longer in the repository holds nothing, so a renamed proposal's
	// address goes with it.
	for f, a := range c.pins {
		if !c.proposals[f] {
			continue
		}
		if o := owners[a]; o != "" && o != f {
			return q(o) + ": the subaddress " + q(f) + " has on the live site"
		}
		if _, ok := d.State[f]; !ok {
			return q(f) + ": no state, where the live site has given it a subaddress (the gate's pins)"
		}
	}
	for f, x := range d.Funds {
		switch {
		case !c.proposals[f]:
			return q(f) + ": funds of no proposal in the proposals repository"
		case x == nil || x.Amount == nil || x.Raised == nil || x.Needed == nil || x.Pending == nil || x.Count == nil || x.Percentage == nil:
			return q(f) + ": funds without all of amount, raised, pending, count, percentage, needed"
		case !xmr4Rx.MatchString(*x.Amount) || !xmr4Rx.MatchString(*x.Raised) || !xmr4Rx.MatchString(*x.Needed) || !pendingRx.MatchString(string(*x.Pending)):
			return q(f) + ": an amount that isn't one as ccs-bash writes them"
		case *x.Count < 0 || *x.Count > 1e9 || *x.Percentage < 0 || *x.Percentage > 100:
			return q(f) + ": a count or percentage out of range"
		}
	}
	if len(d.Ideas) > 1000 {
		return "over 1000 ideas"
	}
	for i, x := range d.Ideas {
		n := "idea " + strconv.Itoa(i+1)
		switch {
		case x == nil || x.Name == nil || x.GitlabURL == nil || x.Author == nil || x.Date == nil:
			return n + ": without all of name, gitlab-url, author, date"
		case !text(*x.Name) || !text(*x.Author):
			return n + ": a name or author that isn't plain ASCII text (escaped, no run of 90 that could be an address)"
		case address(*x.Name) || address(*x.Author):
			return n + ": an address in its name or author (whole, or in groups)"
		case !c.link.MatchString(*x.GitlabURL):
			return n + ": a link that isn't a merge request of the proposals repository"
		case !dateRx.MatchString(*x.Date):
			return n + ": a date that isn't one"
		case x.CreatedAt != nil && !utc(*x.CreatedAt):
			// Optional, so a gate updated first still takes an older backend's push
			return n + ": a created-at that isn't a UTC time"
		case x.Upvotes != nil && *x.Upvotes < 0, x.Downvotes != nil && *x.Downvotes < 0:
			return n + ": a vote count below 0"
		}
	}
	return ""
}

// Ideas returns the ideas in b (a JSON array of objects) without those the data check refuses
// for their name or author (text, address), and for each one dropped, its link and why. The
// backend runs it (ccs-check ideas) before it pushes, since anyone can open an MR: the gate
// itself refuses the whole push for one such idea.
func Ideas(b []byte) ([]byte, []string, error) {
	var all []json.RawMessage
	if err := json.Unmarshal(b, &all); err != nil {
		return nil, nil, errors.New("the ideas aren't a JSON array")
	}
	kept := []json.RawMessage{}
	var dropped []string
	for _, raw := range all {
		var x struct {
			Name      *string `json:"name"`
			Author    *string `json:"author"`
			GitlabURL *string `json:"gitlab-url"`
		}
		if json.Unmarshal(raw, &x) != nil {
			return nil, nil, errors.New("an idea that isn't a JSON object")
		}
		why := ""
		switch {
		case x.Name != nil && !text(*x.Name), x.Author != nil && !text(*x.Author):
			why = "a name or author that isn't plain ASCII text"
		case x.Name != nil && address(*x.Name), x.Author != nil && address(*x.Author):
			why = "an address in its name or author"
		}
		if why == "" {
			kept = append(kept, raw)
			continue
		}
		link := "(no link)"
		if x.GitlabURL != nil {
			link = q(*x.GitlabURL)
		}
		dropped = append(dropped, link+": "+why)
	}
	var out bytes.Buffer
	enc := json.NewEncoder(&out)
	enc.SetEscapeHTML(false)
	err := enc.Encode(kept)
	return out.Bytes(), dropped, err
}

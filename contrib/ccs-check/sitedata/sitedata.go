// Package sitedata: site-data.json, the backend's whole push: what only it knows, the inputs of
// ccs-bash's lib/site.jq but what the web server reads from the proposals repository itself (the
// front matter, each proposal's merge request): each proposal's subaddress index and dates, its
// funds, the ideas. The web server builds the site from it (ccs-gate-build) once it passes here:
// every key once as Go reads it, no other key, each value of its kind: an index the signed list
// has, never 0 (the wallet's main address) nor two proposals' one, and the address the live site
// has for the proposal (its projects.json); amounts as ccs-bash's xmr4 writes them; an idea's name
// and author plain text, its link a merge request of the proposals repository.
package sitedata

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"os"
	"regexp"
	"strconv"
	"strings"
	"unicode/utf8"
)

type stateEntry struct {
	GitlabURL           *string `json:"gitlab_url"`
	SubaddrIndex        *int64  `json:"subaddr_index"`
	FundingRequiredDate *string `json:"funding_required_date"`
	FundedDate          *string `json:"funded_date"`
}

type fundEntry struct {
	Amount, Raised, Needed *string
	Pending                *json.Number
	Count, Percentage      *int64
}

type ideaEntry struct {
	Name      *string `json:"name"`
	GitlabURL *string `json:"gitlab-url"`
	Author    *string `json:"author"`
	Date      *string `json:"date"`
	Upvotes   *int64  `json:"upvotes"`
	Downvotes *int64  `json:"downvotes"`
}

type siteData struct {
	State map[string]*stateEntry `json:"state"`
	Funds map[string]*fundEntry  `json:"funds"`
	Ideas []*ideaEntry           `json:"ideas"`
}

// Max: a larger site-data.json is not read (the real one, 316 proposals, is about 100 kB)
const Max = 4 << 20

var (
	xmr4Rx    = regexp.MustCompile(`^[0-9]{1,7}\.[0-9]{4}$`)
	pendingRx = regexp.MustCompile(`^[0-9]{1,7}(\.[0-9]{1,4})?$`)
	utcRx     = regexp.MustCompile(`^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$`)
	// an idea's date, as ccs-bash writes it ("October 1, 2026"), or none
	dateRx = regexp.MustCompile(`^((January|February|March|April|May|June|July|August|September|October|November|December) [1-9][0-9]?, [0-9]{4})?$`)
	ents   = []string{"&amp;", "&lt;", "&gt;", "&quot;", "&#39;", "&apos;"}
)

// Checker: what site-data.json is checked against
type Checker struct {
	index     map[string]string // the signed list's addresses, by index
	proposals map[string]bool   // the proposals (file.md) in the repository's commits fetched
	pins      map[string]string // the live site's address of each of them, the list's
	link      *regexp.Regexp    // a merge request of the proposals repository
}

// New: from the signed list ("index address" lines), the proposals in the repository (a file of
// their names, file.md, one a line), HOSTS (where the repository is: host/path, space-separated)
// and the live site (its projects.json: the addresses its proposals have; "": none)
func New(list, proposals, hosts, live string) (*Checker, error) {
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
	if live != "" {
		for f, a := range addresses(live) {
			if listed[a] && c.proposals[f] {
				c.pins[f] = a
			}
		}
	}
	return c, nil
}

// addresses: each proposal's (filename) address in the projects.json in dir, as the gate built it
// (none if it can't be read: then every proposal is new to the site)
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

// text: escaped text as ccs-bash writes an idea's name and author (jq @html): no markup, no bidi
// controls, at most 1000 characters (an entity one), and no run of 90 characters that could be
// an address's (base58, or any not ASCII, which could stand for one)
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
		} else if strings.ContainsRune("<>\"'", r) || r <= 0x1f || r == 0x7f || r >= 0x202a && r <= 0x202e || r >= 0x2066 && r <= 0x2069 {
			return false
		}
		if w == 1 || r > 0x7f {
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

// a character of an address, or one that could stand for one (any not ASCII)
func isRun(r rune) bool {
	return r > 0x7f || r >= '1' && r <= '9' || r >= 'A' && r <= 'Z' && r != 'I' && r != 'O' || r >= 'a' && r <= 'z' && r != 'l'
}

// read: b as siteData, strictly: no unknown key, nothing after it
func read(b []byte) (*siteData, error) {
	dec := json.NewDecoder(bytes.NewReader(b))
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

// Check: "" if site-data.json (its bytes b) passes, else why not
func (c *Checker) Check(b []byte) string {
	if len(b) > Max {
		return "a site-data.json over 4 MB"
	}
	d, err := read(b)
	if err != nil {
		return "a site-data.json that isn't as ccs-bash writes it (" + err.Error() + ")"
	}
	owners := map[string]string{}
	for f, s := range d.State {
		switch {
		case !c.proposals[f]:
			return f + ": no proposal in the proposals repository"
		case s == nil:
			return f + ": no state"
		case s.GitlabURL != nil && !c.link.MatchString(*s.GitlabURL):
			return f + ": a link that isn't a merge request of the proposals repository"
		case s.FundingRequiredDate != nil && !utcRx.MatchString(*s.FundingRequiredDate),
			s.FundedDate != nil && !utcRx.MatchString(*s.FundedDate):
			return f + ": a date that isn't one (UTC, as ccs-bash writes them)"
		}
		if s.SubaddrIndex == nil {
			continue
		}
		a, ok := c.index[strconv.FormatInt(*s.SubaddrIndex, 10)]
		switch {
		case *s.SubaddrIndex <= 0 || !ok:
			return f + ": a subaddress index the signed list hasn't (or the wallet's main address)"
		case owners[a] != "":
			return f + ": the subaddress " + owners[a] + " has"
		}
		owners[a] = f
		if p, pin := c.pins[f]; pin && p != a {
			return f + ": another subaddress than the live site has for it"
		}
	}
	for f, a := range c.pins {
		if o := owners[a]; o != "" && o != f {
			return o + ": the subaddress " + f + " has on the live site"
		}
	}
	for f, x := range d.Funds {
		switch {
		case !c.proposals[f]:
			return f + ": funds of no proposal in the proposals repository"
		case x == nil || x.Amount == nil || x.Raised == nil || x.Needed == nil || x.Pending == nil || x.Count == nil || x.Percentage == nil:
			return f + ": funds without all of amount, raised, pending, count, percentage, needed"
		case !xmr4Rx.MatchString(*x.Amount) || !xmr4Rx.MatchString(*x.Raised) || !xmr4Rx.MatchString(*x.Needed) || !pendingRx.MatchString(string(*x.Pending)):
			return f + ": an amount that isn't one as ccs-bash writes them"
		case *x.Count < 0 || *x.Count > 1e9 || *x.Percentage < 0 || *x.Percentage > 100:
			return f + ": a count or percentage out of range"
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
			return n + ": a name or author that isn't plain text (escaped, no bidi controls, no run of 90 that could be an address)"
		case !c.link.MatchString(*x.GitlabURL):
			return n + ": a link that isn't a merge request of the proposals repository"
		case !dateRx.MatchString(*x.Date):
			return n + ": a date that isn't one"
		case x.Upvotes != nil && *x.Upvotes < 0, x.Downvotes != nil && *x.Downvotes < 0:
			return n + ": a vote count below 0"
		}
	}
	return ""
}

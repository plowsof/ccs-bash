package pages

// site-data.json: what only the backend knows, the inputs of ccs-bash's lib/site.jq but the front
// matter (which the gate reads from the repository itself): each proposal's subaddress index,
// merge request and dates, its funds, the ideas. Checked here so the web server can build the site
// from it; every key once as Go reads it, no other key, each value of
// its kind: an index the signed list has, never 0 (the wallet's main address) nor two proposals'
// one, and the address the live site has for the proposal (projects.go's pins); amounts as
// ccs-bash's xmr4 writes them; an idea's name and author TEXT, its link a merge request of the
// proposals repository.

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"regexp"
	"strconv"
	"strings"
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

var (
	xmr4Rx    = regexp.MustCompile(`^[0-9]{1,7}\.[0-9]{4}$`)
	pendingRx = regexp.MustCompile(`^[0-9]{1,7}(\.[0-9]{1,4})?$`)
	utcRx     = regexp.MustCompile(`^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$`)
)

// readSiteData: b as siteData, strictly: no unknown key, nothing after it
func readSiteData(b []byte) (*siteData, error) {
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

// whole: t matches n from its start to its end
func whole(n node, t string) bool { return fullmatch(newCtx([]rune(t)), n) }

// siteData: "" if site-data.json (its bytes b) passes, else why not
func (c *Checker) siteData(b []byte) string {
	d, err := readSiteData(b)
	if err != nil {
		return "a site-data.json that isn't as ccs-bash writes it (" + err.Error() + ")"
	}
	proposal := func(f string) bool {
		return strings.HasSuffix(f, ".md") && len(c.fronts[strings.TrimSuffix(f, ".md")]) > 0
	}
	owners := map[string]string{}
	for f, s := range d.State {
		switch {
		case !proposal(f):
			return "site-data.json, " + f + ": no proposal in the proposals repository"
		case s == nil:
			return "site-data.json, " + f + ": no state"
		case s.GitlabURL != nil && !whole(c.link, *s.GitlabURL):
			return "site-data.json, " + f + ": a link that isn't a merge request of the proposals repository"
		case s.FundingRequiredDate != nil && !utcRx.MatchString(*s.FundingRequiredDate),
			s.FundedDate != nil && !utcRx.MatchString(*s.FundedDate):
			return "site-data.json, " + f + ": a date that isn't one (UTC, as ccs-bash writes them)"
		}
		if s.SubaddrIndex == nil {
			continue
		}
		a, ok := c.l.index[strconv.FormatInt(*s.SubaddrIndex, 10)]
		switch {
		case *s.SubaddrIndex <= 0 || !ok:
			return "site-data.json, " + f + ": a subaddress index the signed list hasn't (or the wallet's main address)"
		case owners[a] != "":
			return "site-data.json, " + f + ": the subaddress " + owners[a] + " has"
		}
		owners[a] = f
		if p, pin := c.pins[f]; pin && p != a {
			return "site-data.json, " + f + ": another subaddress than the live site has for it"
		}
	}
	for f, a := range c.pins {
		if o := owners[a]; o != "" && o != f {
			return "site-data.json, " + o + ": the subaddress " + f + " has on the live site"
		}
	}
	for f, x := range d.Funds {
		switch {
		case !proposal(f):
			return "site-data.json, " + f + ": funds of no proposal in the proposals repository"
		case x == nil || x.Amount == nil || x.Raised == nil || x.Needed == nil || x.Pending == nil || x.Count == nil || x.Percentage == nil:
			return "site-data.json, " + f + ": funds without all of amount, raised, pending, count, percentage, needed"
		case !xmr4Rx.MatchString(*x.Amount) || !xmr4Rx.MatchString(*x.Raised) || !xmr4Rx.MatchString(*x.Needed) || !pendingRx.MatchString(string(*x.Pending)):
			return "site-data.json, " + f + ": an amount that isn't one as ccs-bash writes them"
		case *x.Count < 0 || *x.Count > 1e9 || *x.Percentage < 0 || *x.Percentage > 100:
			return "site-data.json, " + f + ": a count or percentage out of range"
		}
	}
	if len(d.Ideas) > 1000 {
		return "site-data.json: over 1000 ideas"
	}
	for i, x := range d.Ideas {
		n := "site-data.json, idea " + strconv.Itoa(i+1)
		switch {
		case x == nil || x.Name == nil || x.GitlabURL == nil || x.Author == nil || x.Date == nil:
			return n + ": without all of name, gitlab-url, author, date"
		case !whole(TEXT, *x.Name) || !whole(TEXT, *x.Author):
			return n + ": a name or author that isn't plain text (escaped, no bidi controls, no run of 90 that could be an address)"
		case !whole(c.link, *x.GitlabURL):
			return n + ": a link that isn't a merge request of the proposals repository"
		case !whole(DATE, *x.Date):
			return n + ": a date that isn't one"
		case x.Upvotes != nil && *x.Upvotes < 0, x.Downvotes != nil && *x.Downvotes < 0:
			return n + ": a vote count below 0"
		}
	}
	return ""
}

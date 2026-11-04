package pages

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// site-data.json as ccs-bash writes it, for projectsSetup's proposals (p and q live with addrA and
// addrB, indexes 1 and 2 of the list; r new)
const goodSiteData = `{
    "state": {
        "p.md": {"gitlab_url": "https://repo.example/ccs/-/merge_requests/3", "subaddr_index": 1, "funding_required_date": "2026-10-25T13:00:00Z", "funded_date": null},
        "q.md": {"gitlab_url": null, "subaddr_index": 2, "funding_required_date": null, "funded_date": null},
        "r.md": {"gitlab_url": null, "subaddr_index": 3, "funding_required_date": null, "funded_date": null}
    },
    "funds": {
        "p.md": {"amount": "10.5000", "raised": "1.0500", "pending": 0.1, "count": 2, "percentage": 10, "needed": "9.3500"},
        "q.md": {"amount": "5.0000", "raised": "0.0000", "pending": 0, "count": 0, "percentage": 0, "needed": "5.0000"}
    },
    "ideas": [{"name": "An idea &amp; more", "gitlab-url": "https://repo.example/ccs/-/merge_requests/9", "author": "erin", "date": "October 1, 2026", "upvotes": 5, "downvotes": null}]
}`

func TestSiteData(t *testing.T) {
	design, bodies, fronts, list, live := projectsSetup(t)
	c, err := New(design, bodies, list, "", "repo.example/ccs", "", fronts, live)
	if err != nil {
		t.Fatal(err)
	}
	r := func(old, new string) string { return strings.Replace(goodSiteData, old, new, 1) }
	for name, x := range map[string]struct {
		json string
		ok   bool
	}{
		"as ccs-bash writes it":  {goodSiteData, true},
		"a key more":             {r(`"funded_date": null},`, `"funded_date": null, "address": "x"},`), false},
		"a key more, at the top": {r(`"ideas": [`, `"pages": "<p>", "ideas": [`), false},
		"no ideas":               {r(`"ideas": [{"name": "An idea &amp; more", "gitlab-url": "https://repo.example/ccs/-/merge_requests/9", "author": "erin", "date": "October 1, 2026", "upvotes": 5, "downvotes": null}]`, `"ideas": []`), true},
		"ideas left out": {r(`,
    "ideas": [{"name": "An idea &amp; more", "gitlab-url": "https://repo.example/ccs/-/merge_requests/9", "author": "erin", "date": "October 1, 2026", "upvotes": 5, "downvotes": null}]`, ``), false},
		"something after it":               {goodSiteData + "{}", false},
		"no such proposal":                 {r(`"r.md"`, `"x.md"`), false},
		"funds of no proposal":             {r(`"q.md": {"amount"`, `"x.md": {"amount"`), false},
		"index 0 (the main address)":       {r(`"subaddr_index": 3`, `"subaddr_index": 0`), false},
		"an index the list hasn't":         {r(`"subaddr_index": 3`, `"subaddr_index": 99`), false},
		"two proposals, one index":         {r(`"subaddr_index": 3`, `"subaddr_index": 2`), false},
		"q given p's index":                {r(`"subaddr_index": 2`, `"subaddr_index": 1`), false},
		"another index than the live site": {r(`"subaddr_index": 1`, `"subaddr_index": 3`), false},
		"a link to another forge":          {r(`repo.example/ccs/-/merge_requests/3`, `evil.example/x/-/merge_requests/3`), false},
		"a date that isn't one":            {r(`2026-10-25T13:00:00Z`, `yesterday`), false},
		"an amount as a number":            {r(`"amount": "10.5000"`, `"amount": 10.5`), false},
		"an amount of 3 decimals":          {r(`"10.5000"`, `"10.500"`), false},
		"funds without needed":             {r(`, "needed": "5.0000"`, ``), false},
		"a percentage over 100":            {r(`"percentage": 10`, `"percentage": 101`), false},
		"markup in an idea's name":         {r(`An idea &amp; more`, `An <b>idea</b>`), false},
		"an address-long run in a name":    {r(`An idea &amp; more`, strings.Repeat("A", 90)), false},
		"a bidi control in an author":      {r(`"erin"`, "\"er‮in\""), false},
		"an idea's link out":               {r(`repo.example/ccs/-/merge_requests/9`, `evil.example/ccs/-/merge_requests/9`), false},
		"an idea's date that isn't one":    {r(`October 1, 2026`, `soon`), false},
	} {
		site := t.TempDir()
		os.WriteFile(filepath.Join(site, "site-data.json"), []byte(x.json), 0o644)
		if got := run(t, c, site, "site-data.json"); (got == "=ok\n") != x.ok {
			t.Errorf("%s: %q", name, got)
		}
	}
}

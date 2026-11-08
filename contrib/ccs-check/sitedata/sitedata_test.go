package sitedata

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

var (
	addrA = "4" + strings.Repeat("A", 94)
	addrB = "4" + strings.Repeat("B", 94)
	addrC = "4" + strings.Repeat("C", 94)
)

// site-data.json as ccs-bash writes it, for setup's proposals: p and q are live with addrA and
// addrB (list indexes 1 and 2); r is new
const good = `{
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

// setup makes a list (0, then addrA, addrB, addrC as 1 to 3), the proposals p, q and r, and a
// live site where p and q have addrA and addrB
func setup(t testing.TB) *Checker {
	d := t.TempDir()
	list, props, live := filepath.Join(d, "list.txt"), filepath.Join(d, "proposals"), filepath.Join(d, "live")
	os.WriteFile(list, []byte("0 9"+strings.Repeat("W", 94)+"\n1 "+addrA+"\n2 "+addrB+"\n3 "+addrC+"\n"), 0o644)
	os.WriteFile(props, []byte("p.md\nq.md\nr.md\n"), 0o644)
	os.Mkdir(live, 0o755)
	os.WriteFile(filepath.Join(live, "projects.json"), []byte(`[{"filename":"p.md","address":"`+addrA+`"},{"filename":"q.md","address":"`+addrB+`"}]`), 0o644)
	c, err := New(list, props, "repo.example/ccs", live, filepath.Join(d, "pins"))
	if err != nil {
		t.Fatal(err)
	}
	return c
}

func TestCheck(t *testing.T) {
	c := setup(t)
	r := func(old, new string) string { return strings.Replace(good, old, new, 1) }
	for name, x := range map[string]struct {
		json string
		ok   bool
	}{
		"as ccs-bash writes it":  {good, true},
		"a key more":             {r(`"funded_date": null},`, `"funded_date": null, "address": "x"},`), false},
		"a key more, at the top": {r(`"ideas": [`, `"pages": "<p>", "ideas": [`), false},
		"no ideas":               {r(`"ideas": [{"name": "An idea &amp; more", "gitlab-url": "https://repo.example/ccs/-/merge_requests/9", "author": "erin", "date": "October 1, 2026", "upvotes": 5, "downvotes": null}]`, `"ideas": []`), true},
		"ideas left out": {r(`,
    "ideas": [{"name": "An idea &amp; more", "gitlab-url": "https://repo.example/ccs/-/merge_requests/9", "author": "erin", "date": "October 1, 2026", "upvotes": 5, "downvotes": null}]`, ``), false},
		"something after it":               {good + "{}", false},
		"an idea's created-at":             {r(`"date": "October 1, 2026",`, `"date": "October 1, 2026", "created-at": "2026-10-01T12:34:56Z",`), true},
		"a created-at that isn't UTC":      {r(`"date": "October 1, 2026",`, `"date": "October 1, 2026", "created-at": "2026-10-01 12:34:56",`), false},
		"a created-at that isn't a string": {r(`"date": "October 1, 2026",`, `"date": "October 1, 2026", "created-at": 1,`), false},
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
		"a bare & in a name":               {r(`An idea &amp; more`, `An idea & more`), false},
		"an address-long run in a name":    {r(`An idea &amp; more`, strings.Repeat("A", 90)), false},
		"89 of one, then a space":          {r(`An idea &amp; more`, strings.Repeat("A", 89)+" "+strings.Repeat("A", 89)), true},
		"a run not ASCII":                  {r(`An idea &amp; more`, strings.Repeat("é", 90)), false},
		"a bidi control in an author":      {r(`"erin"`, "\"er‮in\""), false},
		"an idea's link out":               {r(`repo.example/ccs/-/merge_requests/9`, `evil.example/ccs/-/merge_requests/9`), false},
		"an idea's date that isn't one":    {r(`October 1, 2026`, `soon`), false},
		// A key Go would read as another, or a duplicate key (jq reads the exact one, the last)
		"STATE beside state":           {r(`"ideas": [`, `"STATE": {}, "ideas": [`), false},
		"Subaddr_Index":                {r(`"subaddr_index": 3`, `"Subaddr_Index": 3`), false},
		"an index twice":               {r(`"subaddr_index": 3`, `"subaddr_index": 3, "subaddr_index": 1`), false},
		"a proposal twice":             {r(`"r.md": {`, `"r.md": {}, "r.md": {`), false},
		"NAME in an idea":              {r(`"name": "An idea`, `"NAME": "x", "name": "An idea`), false},
		"Amount in funds":              {r(`"amount": "10.5000"`, `"Amount": "10.5000"`), false},
		"a key escaped as itself":      {r(`"subaddr_index": 3`, `"subaddr_\u0069ndex": 3`), true},
		"not UTF-8":                    {r(`erin`, "er\xffin"), false},
		"an object where a value goes": {r(`"subaddr_index": 3`, `"subaddr_index": {"a": 1}`), false},
		// A proposal the live site gave an address keeps it, even if the push has null or leaves it out
		"p's index null": {r(`"subaddr_index": 1`, `"subaddr_index": null`), false},
		"p left out":     {r(`"p.md": {"gitlab_url": "https://repo.example/ccs/-/merge_requests/3", "subaddr_index": 1, "funding_required_date": "2026-10-25T13:00:00Z", "funded_date": null},`, ``), false},
		"r's index null": {r(`"subaddr_index": 3`, `"subaddr_index": null`), true},
		// An address in an idea's name, in groups, or in look-alike letters
		"an address in groups in a name": {r(`An idea &amp; more`, "Send to "+groups(fund, 4, "")), false},
		"one Cyrillic а, in groups":      {r(`An idea &amp; more`, "Send to "+groups(fund, 4, "а")), false},
		"full-width, in groups":          {r(`An idea &amp; more`, "Send to "+groups(fund, 4, "Ａ")), false},
		"groups of no address":           {r(`An idea &amp; more`, "Send to "+groups(fund[:90]+"xxxxx", 4, "")), true},
	} {
		if why := c.Check([]byte(x.json)); (why == "") != x.ok {
			t.Errorf("%s: %q", name, why)
		}
	}
}

// The General Fund: a valid address by its checksum
const fund = "44AFFq5kSiGBoZ4NMDwYtN18obc8AemS33DBLWs3H7otXft3XjrpDtQGv7SqSsaBYBb98uNbr2VBBEt7f2wfn3RVGQBEP3A"

// groups returns a in groups of n, space-separated, with its first a (for sub "а") or A (for "Ａ")
// replaced by sub
func groups(a string, n int, sub string) string {
	var g []string
	for len(a) > n {
		g, a = append(g, a[:n]), a[n:]
	}
	s := strings.Join(append(g, a), " ")
	if sub != "" {
		s = strings.Replace(s, map[string]string{"а": "a", "Ａ": "A"}[sub], sub, 1)
	}
	return s
}

// What the site is built from is exactly what Check read, written again: exact keys, no
// duplicates, nothing else
func TestClean(t *testing.T) {
	c := setup(t)
	out, why := c.Clean([]byte(good))
	if why != "" {
		t.Fatal(why)
	}
	if again, why := c.Clean(out); why != "" || string(again) != string(out) {
		t.Errorf("written again, it doesn't pass the same: %q", why)
	}
	for _, k := range []string{`"state"`, `"subaddr_index": 3`, `"amount": "10.5000"`, `"pending": 0.1`, `"gitlab-url"`, `"An idea &amp; more"`} {
		if !strings.Contains(string(out), k) {
			t.Errorf("no %s in %s", k, out)
		}
	} // An idea without created-at stays without it (no null), and one with it keeps it
	if strings.Contains(string(out), "created-at") {
		t.Errorf("created-at written for an idea that had none: %s", out)
	}
	with := strings.Replace(good, `"date": "October 1, 2026",`, `"date": "October 1, 2026", "created-at": "2026-10-01T12:34:56Z",`, 1)
	if out, why := c.Clean([]byte(with)); why != "" || !strings.Contains(string(out), `"created-at": "2026-10-01T12:34:56Z"`) {
		t.Errorf("created-at not kept: %q %s", why, out)
	}
}

// The gate's pins win over projects.json, and keep the address of a proposal hidden from it
func TestPins(t *testing.T) {
	d := t.TempDir()
	list, props, live, pins := filepath.Join(d, "list.txt"), filepath.Join(d, "proposals"), filepath.Join(d, "live"), filepath.Join(d, "pins")
	os.WriteFile(list, []byte("1 "+addrA+"\n2 "+addrB+"\n3 "+addrC+"\n"), 0o644)
	os.WriteFile(props, []byte("p.md\nq.md\nr.md\n"), 0o644)
	os.Mkdir(live, 0o755)
	// p hidden from the live site's projects.json for one push; the pins still have it, and r's too
	os.WriteFile(filepath.Join(live, "projects.json"), []byte(`[{"filename":"q.md","address":"`+addrB+`"},{"filename":"r.md","address":"`+addrA+`"}]`), 0o644)
	os.WriteFile(pins, []byte("p.md "+addrA+"\nr.md "+addrC+"\ngone.md 4nothere\n"), 0o644)
	c, err := New(list, props, "repo.example/ccs", live, pins)
	if err != nil {
		t.Fatal(err)
	}
	if why := c.Check([]byte(good)); why != "" {
		t.Errorf("pinned as they are: %q", why)
	}
	if why := c.Check([]byte(strings.Replace(good, `"subaddr_index": 1`, `"subaddr_index": null`, 1))); why == "" {
		t.Errorf("p hidden from projects.json, then given no index: passed")
	}
	if why := c.Check([]byte(strings.Replace(strings.Replace(good, `"subaddr_index": 1`, `"subaddr_index": 9`, 1), `"subaddr_index": 3`, `"subaddr_index": 1`, 1))); why == "" {
		t.Errorf("r given p's pinned address: passed")
	}
	// p renamed (p.md gone from the repository, s.md its new name): its address goes with it
	os.WriteFile(props, []byte("s.md\nq.md\nr.md\n"), 0o644)
	if c, err = New(list, props, "repo.example/ccs", live, pins); err != nil {
		t.Fatal(err)
	}
	if why := c.Check([]byte(strings.Replace(good, `"p.md"`, `"s.md"`, 2))); why != "" {
		t.Errorf("a renamed proposal keeping its address: %q", why)
	}
}

// A name of 1000 characters passes, 1001 doesn't; an entity counts as one
func TestTextLength(t *testing.T) {
	long := strings.Repeat("ab ", 333) + "a"
	if !text(long) || text(long+"b") {
		t.Errorf("1000 characters at most")
	}
	if !text(strings.Repeat("&amp;", 1000)) || text(strings.Repeat("&amp;", 1001)) {
		t.Errorf("an entity is one character")
	}
}

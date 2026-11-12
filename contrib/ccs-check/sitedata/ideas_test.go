package sitedata

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// An address in groups of 4, as an MR title could hold it
func fundGroups() string { return groups(fund, 4, "") }

func TestIdeas(t *testing.T) {
	idea := func(name string) string {
		return `{"name": "` + name + `", "gitlab-url": "https://repo.example/ccs/-/merge_requests/9", "author": "erin", "date": "October 1, 2026"}`
	}
	in := "[" + idea("A plain idea &amp; more") + "," + idea(strings.Replace(fundGroups(), "A", "А", 1)) + "," +
		idea(strings.Replace(fundGroups(), "A", "ꓮ", 1)) + "," + idea(strings.Replace(fundGroups(), "tN18 obc8", "tNא8 1אobc8", 1)) + "," +
		idea("a‏b") + "]"
	out, dropped, err := Ideas([]byte(in))
	if err != nil {
		t.Fatal(err)
	}
	if len(dropped) != 4 || !strings.Contains(string(out), "A plain idea &amp; more") || strings.Count(string(out), `"name"`) != 1 {
		t.Errorf("kept %s, dropped %q", out, dropped)
	}
	if _, _, err := Ideas([]byte(`{}`)); err == nil {
		t.Errorf("not an array: no error")
	}
}

func TestDates(t *testing.T) {
	c := setup(t)
	r := func(old, new string) string { return strings.Replace(good, old, new, 1) }
	for name, x := range map[string]struct {
		json string
		ok   bool
	}{
		"a real date":       {r(`"date": "October 1, 2026",`, `"date": "October 1, 2026", "created-at": "2026-10-01T12:34:56Z",`), true},
		"month 13":          {r(`"date": "October 1, 2026",`, `"date": "October 1, 2026", "created-at": "2026-13-01T00:00:00Z",`), false},
		"hour 24":           {r(`"date": "October 1, 2026",`, `"date": "October 1, 2026", "created-at": "2026-10-01T24:00:00Z",`), false},
		"February 30":       {r(`"2026-10-25T13:00:00Z"`, `"2026-02-30T13:00:00Z"`), false},
		"far ahead":         {r(`"date": "October 1, 2026",`, `"date": "October 1, 2026", "created-at": "9999-12-31T23:59:59Z",`), false},
		"funded, far ahead": {r(`"funded_date": null},`, `"funded_date": "9999-12-31T23:59:59Z"},`), false},
	} {
		if why := c.Check([]byte(x.json)); (why == "") != x.ok {
			t.Errorf("%s: %q", name, why)
		}
	}
}

// A reason quotes a proposal's name, so a name with control characters can't break a log line
func TestQuotedName(t *testing.T) {
	why := setup(t).Check([]byte(strings.Replace(good, `"r.md"`, `"\u001b]0;x\u0007\nURGENT.md"`, 1)))
	if strings.ContainsAny(why, "\x1b\x07\n") {
		t.Errorf("a raw control character in %q", why)
	}
}

// Names with spaces are pinned, the address being after the last space
func TestPinsWithSpaces(t *testing.T) {
	d := t.TempDir()
	list, props, pins := filepath.Join(d, "list.txt"), filepath.Join(d, "proposals"), filepath.Join(d, "pins")
	os.WriteFile(list, []byte("1 "+addrA+"\n2 "+addrB+"\n3 "+addrC+"\n"), 0o644)
	os.WriteFile(props, []byte("a b.md\n c.md\nq.md\n"), 0o644)
	os.WriteFile(pins, []byte("a b.md "+addrA+"\n c.md "+addrB+"\n"), 0o644)
	c, err := New(list, props, "repo.example/ccs", "", pins)
	if err != nil {
		t.Fatal(err)
	}
	data := func(ab, cc int) string {
		return `{"state": {"a b.md": {"gitlab_url": null, "subaddr_index": ` + string(rune('0'+ab)) + `, "funding_required_date": null, "funded_date": null},
		" c.md": {"gitlab_url": null, "subaddr_index": ` + string(rune('0'+cc)) + `, "funding_required_date": null, "funded_date": null}}, "funds": {}, "ideas": []}`
	}
	if why := c.Check([]byte(data(1, 2))); why != "" {
		t.Errorf("as pinned: %q", why)
	}
	if why := c.Check([]byte(data(2, 1))); why == "" {
		t.Errorf("the two names' addresses swapped: passed")
	}
}

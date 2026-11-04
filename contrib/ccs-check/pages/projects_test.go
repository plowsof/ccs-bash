package pages

import (
	"bufio"
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// three of the list's addresses (index 1, 2, 3) and one not in it
var (
	addrA   = "4" + strings.Repeat("A", 94)
	addrB   = "4" + strings.Repeat("B", 94)
	addrC   = "4" + strings.Repeat("C", 94)
	addrOut = "4" + strings.Repeat("D", 94)
)

// a small design (a page with a donation box), the proposals p and q (the newest commit) and r
// (in the older one only), and a live site whose projects.json gives p addrA and q addrB
func projectsSetup(t *testing.T) (design, bodies, fronts, list, live string) {
	design = t.TempDir()
	for name, text := range map[string]string{
		"parts/proposal-fr.html":  "<h1>{{name}}</h1>\n<!-- ccs:donate -->\n<!-- /ccs:donate -->\n{{body}}\n</html>",
		"parts/proposal-wip.html": "<h1>{{name}}</h1>{{body}}\n</html>", "parts/proposal-cp.html": "<h1>{{name}}</h1>{{body}}\n</html>",
		"parts/donate.html": "<p>{{address}}</p><img src=\"{{qr}}\">\n", "parts/verify-link.html": "\n",
		"parts/segment-done.html": "<i></i>\n", "parts/segment-todo.html": "<b></b>\n",
		"parts/label-link.html": "<a class=\"label {{color}}\" href=\"{{href}}\">{{tag}}</a>\n", "parts/label.html": "<span class=\"label {{color}}\">{{tag}}</span>\n",
	} {
		os.MkdirAll(filepath.Dir(filepath.Join(design, name)), 0o755)
		if err := os.WriteFile(filepath.Join(design, name), []byte(text), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	tmp := t.TempDir()
	bodies = filepath.Join(tmp, "b.jsonl")
	var b strings.Builder
	for _, n := range []string{"p", "q", "r"} {
		b.WriteString(`{"file":"` + n + `","body":"<p>Text</p>","milestones":[],"payouts":[]}` + "\n")
	}
	os.WriteFile(bodies, []byte(b.String()), 0o644)
	head, old := filepath.Join(tmp, "f1.tsv"), filepath.Join(tmp, "f2.tsv")
	os.WriteFile(head, []byte("p.md\tfr\tP & co\tsome'one\t2026 10 22\t10.50\t\t1\t0\t\n"+
		"q.md\tfr\tQ\tanother\t2026 10 23\t5\thttps://repo.example/ccs/-/merge_requests/7\t1\t0\t\n"), 0o644)
	os.WriteFile(old, []byte("r.md\tfr\tR\tthird\t\t1\t\t1\t0\t\n"), 0o644)
	fronts = head + ":" + old
	list = testList(t)
	f, _ := os.OpenFile(list, os.O_APPEND|os.O_WRONLY, 0o644)
	f.WriteString("1 " + addrA + "\n2 " + addrB + "\n3 " + addrC + "\n")
	f.Close()
	live = t.TempDir()
	os.WriteFile(filepath.Join(live, "projects.json"), []byte(projectsJSON(entryP, entryQ)), 0o644)
	return
}

// the entries as site.jq writes them (jq -c here; the gate reads any spacing)
const (
	entryP = `{"address":"` + "@A" + `","author":"some&#39;one","contributions":2,"date":"October 22, 2026","percentage_funded":10,"raised_amount":1.05,"state":"FUNDING-REQUIRED","target_amount":10.5,"title":"P &amp; co","filename":"p.md","gitlab_url":"https://repo.example/ccs/-/merge_requests/3"}`
	entryQ = `{"address":"` + "@B" + `","author":"another","contributions":0,"date":"October 23, 2026","percentage_funded":0,"raised_amount":0,"state":"FUNDING-REQUIRED","target_amount":5,"title":"Q","filename":"q.md","gitlab_url":"https://repo.example/ccs/-/merge_requests/7"}`
	entryR = `{"address":"` + "@C" + `","author":"third","contributions":null,"date":null,"percentage_funded":null,"raised_amount":null,"state":"FUNDING-REQUIRED","target_amount":1,"title":"R","filename":"r.md","gitlab_url":null}`
)

func projectsJSON(es ...string) string {
	s := "[" + strings.Join(es, ",") + "]\n"
	return strings.NewReplacer("@A", addrA, "@B", addrB, "@C", addrC, "@D", addrOut).Replace(s)
}

func run(t *testing.T, c *Checker, site, rp string) string {
	var b bytes.Buffer
	w := bufio.NewWriter(&b)
	if err := c.Run(site, strings.NewReader(rp+"\x00"), w); err != nil {
		t.Fatal(err)
	}
	return strings.TrimPrefix(b.String(), filepath.Join(site, rp)+"\t")
}

// projects.json: each entry its proposal's front matter, its address the signed list's, one
// proposal's only, and the one the live site has for it
func TestProjects(t *testing.T) {
	design, bodies, fronts, list, live := projectsSetup(t)
	c, err := New(design, bodies, list, "", "repo.example/ccs", "", fronts, live)
	if err != nil {
		t.Fatal(err)
	}
	r := func(old, new string) string { return strings.Replace(entryP, old, new, 1) }
	for name, x := range map[string]struct {
		json string
		ok   bool
	}{
		"as site.jq writes it":       {projectsJSON(entryP, entryQ), true},
		"a new proposal":             {projectsJSON(entryP, entryQ, entryR), true},
		"&apos; for &#39;":           {projectsJSON(r("&#39;", "&apos;"), entryQ), true},
		"spaced out":                 {strings.ReplaceAll(projectsJSON(entryP, entryQ), `,"`, ",\n  \""), true},
		"another title":              {projectsJSON(r(`"P &amp; co"`, `"Donate here"`), entryQ), false},
		"its title unescaped":        {projectsJSON(r(`"P &amp; co"`, `"P & co"`), entryQ), false},
		"another author":             {projectsJSON(r("some&#39;one", "x"), entryQ), false},
		"another date":               {projectsJSON(r("October 22", "October 21"), entryQ), false},
		"another stage":              {projectsJSON(r("FUNDING-REQUIRED", "COMPLETED"), entryQ), false},
		"another goal":               {projectsJSON(r("10.5", "100"), entryQ), false},
		"its goal as a string":       {projectsJSON(r("10.5", `"10.5"`), entryQ), false},
		"a link to another forge":    {projectsJSON(r("repo.example/ccs", "evil.example/ccs"), entryQ), false},
		"a link to another page":     {projectsJSON(r("-/merge_requests/3", "-/issues/3"), entryQ), false},
		"no link":                    {projectsJSON(r(`"https://repo.example/ccs/-/merge_requests/3"`, "null"), entryQ), true},
		"another link than its own":  {projectsJSON(entryP, strings.Replace(entryQ, "requests/7", "requests/8", 1)), false},
		"raised as text":             {projectsJSON(r("1.05", `"1.05"`), entryQ), false},
		"a key more":                 {projectsJSON(r(`"title"`, `"url":"https://evil.example","title"`), entryQ), false},
		"a key less":                 {projectsJSON(r(`"contributions":2,`, ""), entryQ), false},
		"a key twice":                {projectsJSON(r(`"title"`, `"title":"Q","title"`), entryQ), false},
		"a nested value":             {projectsJSON(r("2,", "[2],"), entryQ), false},
		"a proposal twice":           {projectsJSON(entryP, entryP, entryQ), false},
		"no such proposal":           {projectsJSON(entryP, entryQ, strings.Replace(entryR, "r.md", "x.md", 1)), false},
		"something after it":         {projectsJSON(entryP, entryQ) + "[]", false},
		"not an array":               {`{"a":1}`, false},
		"an address not in the list": {projectsJSON(entryP, entryQ, strings.Replace(entryR, "@C", "@D", 1)), false},
		"one address, two proposals": {projectsJSON(entryP, entryQ, strings.Replace(entryR, "@C", "@A", 1)), false},
		"addresses swapped":          {projectsJSON(r("@A", "@B"), strings.Replace(entryQ, "@B", "@A", 1)), false},
		"another address for p":      {projectsJSON(r("@A", "@C"), entryQ), false},
		"no address for p":           {projectsJSON(r(`"@A"`, "null"), entryQ), false},
		"p left out":                 {projectsJSON(entryQ), false},
	} {
		site := t.TempDir()
		os.WriteFile(filepath.Join(site, "projects.json"), []byte(x.json), 0o644)
		if got := run(t, c, site, "projects.json"); (got == "=ok\n") != x.ok {
			t.Errorf("%s: %q", name, got)
		}
	}
}

// a donation box: the address the live site has for its proposal, or for one new to it, the
// push's projects.json's, and never another proposal's
func TestDonationAddress(t *testing.T) {
	design, bodies, fronts, list, live := projectsSetup(t)
	page := func(name, a string) string {
		return "<h1>" + name + "</h1>\n<!-- ccs:donate -->\n<p>" + a + "</p><img src=\"../qr/" + a + ".png\">\n<!-- /ccs:donate -->\n<p>Text</p>\n</html>\n"
	}
	for name, x := range map[string]struct {
		live, proposal, page, json string
		ok                         bool
	}{
		"its own":                         {live, "p", page("P &amp; co", addrA), projectsJSON(entryP, entryQ), true},
		"another proposal's":              {live, "p", page("P &amp; co", addrB), projectsJSON(entryP, entryQ), false},
		"an unused one of the list's":     {live, "p", page("P &amp; co", addrC), projectsJSON(entryP, entryQ), false},
		"swapped in projects.json too":    {live, "p", page("P &amp; co", addrB), projectsJSON(strings.Replace(entryP, "@A", "@B", 1), strings.Replace(entryQ, "@B", "@A", 1)), false},
		"new, as projects.json gives it":  {live, "r", page("R", addrC), projectsJSON(entryP, entryQ, entryR), true},
		"new, not in projects.json":       {live, "r", page("R", addrC), projectsJSON(entryP, entryQ), false},
		"new, another's in projects.json": {live, "r", page("R", addrC), projectsJSON(entryP, entryQ, entryR, strings.Replace(entryP, "p.md", "x.md", 1)), true},
		"new, with a live proposal's":     {live, "r", page("R", addrA), projectsJSON(entryP, entryQ, strings.Replace(entryR, "@C", "@A", 1)), false},
		"no live site: projects.json's":   {"", "p", page("P &amp; co", addrA), projectsJSON(entryP, entryQ), true},
		"no live site: another's":         {"", "p", page("P &amp; co", addrB), projectsJSON(entryP, entryQ), false},
	} {
		c, err := New(design, bodies, list, "", "repo.example/ccs", "", fronts, x.live)
		if err != nil {
			t.Fatal(err)
		}
		site := t.TempDir()
		os.MkdirAll(filepath.Join(site, "proposals"), 0o755)
		os.WriteFile(filepath.Join(site, "projects.json"), []byte(x.json), 0o644)
		os.WriteFile(filepath.Join(site, "proposals", x.proposal+".html"), []byte(x.page), 0o644)
		if got := run(t, c, site, "proposals/"+x.proposal+".html"); (got == "=ok\n") != x.ok {
			t.Errorf("%s: %q", name, got)
		}
	}
}

// a proposal renamed (r.md only in the older commit): the address it had on the live site is free
// for its new name
func TestRenamedAddress(t *testing.T) {
	design, bodies, fronts, list, live := projectsSetup(t)
	os.WriteFile(filepath.Join(live, "projects.json"), []byte(projectsJSON(entryP, entryQ, entryR)), 0o644)
	c, err := New(design, bodies, list, "", "repo.example/ccs", "", fronts, live)
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := c.pins["r.md"]; ok {
		t.Errorf("r.md pinned, though not in the newest commit")
	}
	if c.pins["p.md"] != addrA || c.pins["q.md"] != addrB {
		t.Errorf("pins: %v", c.pins)
	}
}

package pages

import (
	"bufio"
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// testList: a list with index 0 (Verify's) and its .pin, in a temporary folder
func testList(t testing.TB) string {
	d := t.TempDir()
	l := filepath.Join(d, "list.txt")
	if err := os.WriteFile(l, []byte("0 9"+strings.Repeat("W", 94)+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(l+".pin", []byte("key 0123456789ABCDEF0123456789ABCDEF01234567\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	return l
}

// check: what ccs-check pages says of index.html with these contents, against testdata/design
func check(t *testing.T, page string) string {
	site := t.TempDir()
	if err := os.WriteFile(filepath.Join(site, "index.html"), []byte(page), 0o644); err != nil {
		t.Fatal(err)
	}
	c, err := New("testdata/design", "", testList(t), "", "repo.example/ccs", "")
	if err != nil {
		t.Fatal(err)
	}
	var b bytes.Buffer
	w := bufio.NewWriter(&b)
	if err := c.Run(site, strings.NewReader("index.html\x00"), w); err != nil {
		t.Fatal(err)
	}
	return strings.TrimPrefix(b.String(), filepath.Join(site, "index.html")+"\t")
}

func page(title, cards string) string {
	return "<html><h1><!-- ccs:title -->\n" + title + "\n<!-- /ccs:title --></h1>\n<!-- ccs:list idea -->\n" + cards + "\n<!-- /ccs:list idea -->\n</html>\n"
}

func TestPages(t *testing.T) {
	card := func(url, name string) string { return `<a class="card" href="` + url + `">` + name + `</a>` }
	for name, c := range map[string]struct {
		page string
		ok   bool
	}{
		"as the design":      {page("Ideas", card("#", "One")+"\n"+card("./proposals/two.html", "Two &amp; more")), true},
		"no cards":           {page("Ideas", "<p>None yet</p>"), true},
		"a merge request":    {page("Ideas", card("https://repo.example/ccs/-/merge_requests/12", "A")), true},
		"another forge":      {page("Ideas", card("https://evil.example/ccs/-/merge_requests/12", "A")), false},
		"markup in a title":  {page("<b>Ideas</b>", ""), false},
		"an address in text": {page("Ideas "+strings.Repeat("A", 90), ""), false},
		"89 of them":         {page("Ideas "+strings.Repeat("A", 89), ""), true},
		"look-alikes":        {page("Ideas "+strings.Repeat("\uff21", 90), ""), false},
		"a bidi control":     {page("Ideas \u202e", ""), false},
		"something after it": {page("Ideas", "") + "<script>", false},
		"a title of 1001":    {page(strings.Repeat("a ", 500)+"a", ""), false},
	} {
		got := check(t, c.page)
		if c.ok != (got == "=ok\n") {
			t.Errorf("%s: %q", name, got)
		}
	}
}

// the reason says how far the page is the design's, as pages_py's (json.dumps of the next 60)
func TestReason(t *testing.T) {
	got := check(t, page("Ideas", "")+"\u00e9<x>")
	want := `!not a page of the design as ccs-front-bash fills it (it differs at character 116: "\u00e9<x>")` + "\n"
	if got != want {
		t.Errorf("%q, want %q", got, want)
	}
}

// no design: an error, not every page passed; a part that can be empty repeated (here a label,
// the cards' tags): that page not checked, as re would order its tries otherwise (match.go, star)
func TestRefusals(t *testing.T) {
	c, err := New("", "", testList(t), "", "repo.example/ccs", "")
	if err != nil {
		t.Fatal(err)
	}
	var b bytes.Buffer
	if err := c.Run(t.TempDir(), strings.NewReader("index.html\x00"), bufio.NewWriter(&b)); err == nil {
		t.Errorf("no design: %q", b.String())
	}
	d := t.TempDir()
	if err := os.CopyFS(d, os.DirFS("testdata/design")); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(d, "parts", "label.html"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	site := t.TempDir()
	if err := os.WriteFile(filepath.Join(site, "index.html"), []byte(page("Ideas", "")), 0o644); err != nil {
		t.Fatal(err)
	}
	if c, err = New(d, "", testList(t), "", "repo.example/ccs", ""); err != nil {
		t.Fatal(err)
	}
	b.Reset()
	w := bufio.NewWriter(&b)
	if err := c.Run(site, strings.NewReader("index.html\x00"), w); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(b.String(), "could not be checked (error)") {
		t.Errorf("an empty label: %q", b.String())
	}
}

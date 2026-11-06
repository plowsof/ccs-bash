package scan

import (
	"bytes"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

const fund = "44AFFq5kSiGBoZ4NMDwYtN18obc8AemS33DBLWs3H7otXft3XjrpDtQGv7SqSsaBYBb98uNbr2VBBEt7f2wfn3RVGQBEP3A"

func run(t *testing.T, check func([]string, *bytes.Buffer) error, content string) string {
	p := filepath.Join(t.TempDir(), "f")
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	var b bytes.Buffer
	if err := check([]string{p}, &b); err != nil {
		t.Fatal(err)
	}
	return strings.ReplaceAll(b.String(), p+"\t", "")
}

func pages(f []string, b *bytes.Buffer) error { return Pages(f, b) }
func jsons(f []string, b *bytes.Buffer) error { return JSON(f, b) }

func TestPages(t *testing.T) {
	ents := ""
	for _, c := range fund {
		ents += "&#" + strconv.Itoa(int(c)) + ";"
	}
	for name, c := range map[string]struct{ in, want string }{
		"as written":              {"<p>" + fund + "</p>", fund + "\n"},
		"entities":                {"<p>" + ents + "</p>", fund + "\n"},
		"split by a zero-width":   {"<p>" + fund[:40] + "\u200b" + fund[40:] + "</p>", fund + "\n"},
		"not a page":              {"GIF89a", "!not text that starts as a page or JSON does (<, [ or {): a browser would show it as an image\n"},
		"a data: image":           {"<img src=\"data:image/png;base64,QUJD\">", "?qr\tdata:image/png;base64,QUJD\n"},
		"an SVG data: image":      {"<img src=\"data:image/svg+xml,%3Csvg%3E\">", "?qr\tdata:image/svg+xml,%3Csvg%3E\n"},
		"a data: image, any case": {"<img src=\"DATA:Image/JPEG;base64,QUJD\">", "?qr\tDATA:Image/JPEG;base64,QUJD\n"},
		// split between elements a browser lays side by side: two tag labels, a tag and its count
		"two labels": {`<p><span class="label tag-0">` + fund[:48] + `</span><span class="label tag-1">` + fund[48:] + `</span></p>`, fund + "\n"},
		"tag, count": {`<a class="filter" href="x/">` + fund[:89] + `<span class="count">` + fund[89:] + `</span></a>`, fund + "\n"},
		"not one":    {`<p><span>` + fund[:48] + `</span><span>` + fund[48:94] + `x</span></p>`, ""},
		// split by a < or > a browser shows (an entity: text, not markup), as by a - (review 11's M-1)
		"split by &lt;":        {"<h1>" + fund[:47] + "&lt;" + fund[47:] + "</h1>", fund + "\n"},
		"split by &gt;":        {"<h1>" + fund[:47] + " &gt; " + fund[47:] + "</h1>", fund + "\n"},
		"split by &#60;":       {"<h1>" + fund[:47] + "&#60;" + fund[47:] + "</h1>", fund + "\n"},
		"&lt; then a label":    {`<p><span>` + fund[:48] + `</span><span>&lt;` + fund[48:] + `</span></p>`, fund + "\n"},
		"&lt;b&gt; is text":    {"<h1>" + fund[:47] + "&lt;b&gt;" + fund[47:] + "</h1>", ""},
		"&lt; four times, not": {"<h1>" + fund[:47] + "&lt;&lt;&lt;&lt;" + fund[47:] + "</h1>", ""},
		// a named entity without its ";", as a browser reads it: &shy is an unseen soft hyphen (I-2)
		"split by &shy":    {"<h1>" + fund[:47] + "&shy" + fund[47:] + "</h1>", fund + "\n"},
		"split by &AMP":    {"<h1>" + fund[:47] + "&AMP" + fund[47:] + "</h1>", fund + "\n"},
		"&notin is &not":   {"<h1>" + fund[:47] + "&notin" + fund[47:] + "</h1>", ""},
		"&shyx not a name": {"<h1>" + fund[:47] + "&shyx;" + fund[47:] + "</h1>", fund + "\n"},
		// review 12's M-1: a bidi control (an address written backwards shown the right way round),
		// as itself or as an entity; an address with letters drawn as its own (Cyrillic, full-width)
		"U+202E":                {"<p>Send to \u202e" + reverse(grouped(fund, 5)) + "\u202c</p>", Bidi + "\n"},
		"&#x202E;":              {"<p>Send to &#x202E;" + reverse(grouped(fund, 5)) + "&#x202C;</p>", Bidi + "\n"},
		"&#8238;":               {"<p>&#8238;x</p>", Bidi + "\n"},
		"&#x2067; (an isolate)": {"<p>&#X02067;x</p>", Bidi + "\n"},
		"a Cyrillic а":          {"<p>" + strings.Replace(fund, "a", "а", 1) + "</p>", fund + "\n"},
		"a Cyrillic а, grouped": {"<p>" + strings.Replace(grouped(fund, 4), "a", "а", 1) + "</p>", fund + "\n"},
		"&#x430;, grouped":      {"<p>" + strings.Replace(grouped(fund, 4), "a", "&#x430;", 1) + "</p>", fund + "\n"},
		"full-width":            {"<p>" + strings.Replace(fund, "A", "Ａ", 2) + "</p>", fund + "\n"},
		"Cyrillic words":        {"<p>Привет, мир: это предложение.</p>", ""},
	} {
		if got := run(t, pages, c.in); got != c.want {
			t.Errorf("%s: %q", name, got)
		}
	}
}

// grouped: a in groups of n, space-separated (the last group as long as is left)
func grouped(a string, n int) string {
	var g []string
	for len(a) > n {
		g, a = append(g, a[:n]), a[n:]
	}
	return strings.Join(append(g, a), " ")
}

func reverse(s string) string {
	r := []rune(s)
	for i, j := 0, len(r)-1; i < j; i, j = i+1, j-1 {
		r[i], r[j] = r[j], r[i]
	}
	return string(r)
}

func TestJSON(t *testing.T) {
	for name, c := range map[string]struct{ in, want string }{
		"a bidi control":        {`["a\u202eb"]`, Bidi + "\n"},
		"a Cyrillic а, grouped": {`["` + strings.Replace(grouped(fund, 4), "a", "а", 1) + `"]`, fund + "\n"},
		"a key twice":           {`{"a": "x", "a": "` + fund + `"}`, fund + "\n"},
		"split by <":            {`["` + fund[:47] + ` < ` + fund[47:] + `"]`, fund + "\n"},
		"split by \\u003e":      {`["` + fund[:47] + `\u003e` + fund[47:] + `"]`, fund + "\n"},
		"escaped":               {`["` + strings.Join(strings.Split(fund, ""), `\u0000`) + `"]`, fund + "\n"},
		"not JSON":              {`{"a": 1,}`, "!not JSON (UTF-8) that reads\n"},
		"empty":                 {``, "!not JSON (UTF-8) that reads\n"},
		"two values":            {`{} {}`, "!not JSON (UTF-8) that reads\n"},
		"not UTF-8":             {"[\"\xff\"]", "!not JSON (UTF-8) that reads\n"},
		"large number":          {`[1e400]`, ""},
	} {
		if got := run(t, jsons, c.in); got != c.want {
			t.Errorf("%s: %q", name, got)
		}
	}
}

// review 12's M-1: the proposals' text without bidi controls, raw or as entities; the rest as it
// was (36c3.md's "&#x202D;505.96" pasted from a spreadsheet: the number, as a reader sees it)
func TestNobidi(t *testing.T) {
	for in, want := range map[string]string{
		"leading to ‭505.963136971449 XMR": "leading to 505.963136971449 XMR",
		"a &#x202E;b&#X202c; c &#8238;d":   "a b c d",
		"&#x2067;x&#8294;":                 "x",
		"no bidi: é, &amp;, &#x41;, ‏":     "no bidi: é, &amp;, &#x41;, ‏",
		"bad \xff bytes ‮ kept":            "bad \xff bytes  kept",
	} {
		if got := string(Nobidi([]byte(in))); got != want {
			t.Errorf("%q: %q", in, got)
		}
	}
}

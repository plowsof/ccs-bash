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
		"as written":            {"<p>" + fund + "</p>", fund + "\n"},
		"entities":              {"<p>" + ents + "</p>", fund + "\n"},
		"split by a zero-width": {"<p>" + fund[:40] + "\u200b" + fund[40:] + "</p>", fund + "\n"},
		"not a page":            {"GIF89a", "!not text that starts as a page or JSON does (<, [ or {): a browser would show it as an image\n"},
		"a data: image":         {"<img src=\"data:image/png;base64,QUJD\">", "?qr\tQUJD\n"},
		// split between elements a browser lays side by side: two tag labels, a tag and its count
		"two labels": {`<p><span class="label tag-0">` + fund[:48] + `</span><span class="label tag-1">` + fund[48:] + `</span></p>`, fund + "\n"},
		"tag, count": {`<a class="filter" href="x/">` + fund[:89] + `<span class="count">` + fund[89:] + `</span></a>`, fund + "\n"},
		"not one":    {`<p><span>` + fund[:48] + `</span><span>` + fund[48:94] + `x</span></p>`, ""},
	} {
		if got := run(t, pages, c.in); got != c.want {
			t.Errorf("%s: %q", name, got)
		}
	}
}

func TestJSON(t *testing.T) {
	for name, c := range map[string]struct{ in, want string }{
		"a key twice":  {`{"a": "x", "a": "` + fund + `"}`, fund + "\n"},
		"escaped":      {`["` + strings.Join(strings.Split(fund, ""), `\u0000`) + `"]`, fund + "\n"},
		"not JSON":     {`{"a": 1,}`, "!not JSON (UTF-8) that reads\n"},
		"empty":        {``, "!not JSON (UTF-8) that reads\n"},
		"two values":   {`{} {}`, "!not JSON (UTF-8) that reads\n"},
		"not UTF-8":    {"[\"\xff\"]", "!not JSON (UTF-8) that reads\n"},
		"large number": {`[1e400]`, ""},
	} {
		if got := run(t, jsons, c.in); got != c.want {
			t.Errorf("%s: %q", name, got)
		}
	}
}

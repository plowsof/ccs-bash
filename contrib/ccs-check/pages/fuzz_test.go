package pages

import (
	"bufio"
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// any page: exactly one line for it, =ok or a reason (the testdata design's index page)
func FuzzRun(f *testing.F) {
	f.Add(page("Ideas", `<a class="card" href="#">One</a>`))
	f.Add(page(strings.Repeat("A", 89), "<p>None yet</p>"))
	f.Add(page("Ideas", "") + "<x>")
	lst := testList(f)
	c, err := New("testdata/design", "", lst, "", "repo.example/ccs", "")
	if err != nil {
		f.Fatal(err)
	}
	site := f.TempDir()
	f.Fuzz(func(t *testing.T, p string) {
		if err := os.WriteFile(filepath.Join(site, "index.html"), []byte(p), 0o644); err != nil {
			t.Fatal(err)
		}
		var b bytes.Buffer
		w := bufio.NewWriter(&b)
		if err := c.Run(site, strings.NewReader("index.html\x00"), w); err != nil {
			t.Fatal(err)
		}
		out := b.String()
		if strings.Count(out, "\n") != 1 || !(strings.HasSuffix(out, "\t=ok\n") || strings.Contains(out, "\t!")) {
			t.Fatalf("%q", out)
		}
	})
}

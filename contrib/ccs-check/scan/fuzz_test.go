package scan

import (
	"bytes"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// each line: the file, then an address of 95 or 106 letters and digits, a reason, or a data:
// image for the QR reader
var lineRx = regexp.MustCompile(`^(?:[1-9A-HJ-NP-Za-km-z]{95}|[1-9A-HJ-NP-Za-km-z]{106}|[0-9A-Za-z]{95}|[0-9A-Za-z]{106}|![^\t\n]+|\?qr\t[A-Za-z0-9+/]+=*)$`)

func FuzzPages(f *testing.F) {
	for _, s := range []string{"<p>" + fund + "</p>", "{\"a\": \"" + fund + "\"}", "<p>&#52;&#x34;</p>", "GIF89a"} {
		f.Add([]byte(s))
	}
	dir := f.TempDir()
	f.Fuzz(func(t *testing.T, b []byte) {
		p := filepath.Join(dir, "f")
		if err := os.WriteFile(p, b, 0o644); err != nil {
			t.Fatal(err)
		}
		for _, check := range []func([]string, *bytes.Buffer) error{pages, jsons} {
			var out bytes.Buffer
			if err := check([]string{p}, &out); err != nil {
				t.Fatal(err)
			}
			for _, l := range strings.Split(strings.TrimSuffix(out.String(), "\n"), "\n") {
				if l == "" {
					continue
				}
				if !strings.HasPrefix(l, p+"\t") || !lineRx.MatchString(strings.TrimPrefix(l, p+"\t")) {
					t.Fatalf("line %q", l)
				}
			}
		}
	})
}

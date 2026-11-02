package push

import (
	"archive/tar"
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// FuzzReceive: whatever the stream, nothing is written outside the folder, nothing but plain
// files and folders is made, and every name it says it wrote is a file there
func FuzzReceive(f *testing.F) {
	f.Add(stream(f, file("index.html", "<p>x"), entry{name: "a/", typ: tar.TypeDir}, file("a/b.png", "PNG")))
	f.Add(stream(f, entry{name: "x", typ: tar.TypeSymlink, link: "../../etc"}, file("x/y", "z")))
	f.Add(stream(f, entry{name: strings.Repeat("d/", 70) + "f", body: "x", format: tar.FormatPAX}))
	f.Add(make([]byte, 1024))
	f.Fuzz(func(t *testing.T, b []byte) {
		root := t.TempDir()
		dir := filepath.Join(root, "staging")
		os.Mkdir(dir, 0o755)
		files, err := Receive(bytes.NewReader(b), dir, Limits{Total: 1 << 20, File: 1 << 16, Entries: 64})
		filepath.Walk(root, func(p string, i os.FileInfo, err error) error {
			if p != root && p != dir && !strings.HasPrefix(p, dir+string(filepath.Separator)) {
				t.Fatalf("written outside: %s", p)
			}
			if i != nil && !i.Mode().IsRegular() && !i.IsDir() {
				t.Fatalf("not a plain file or folder: %s %v", p, i.Mode())
			}
			return nil
		})
		if err == nil {
			for _, n := range files {
				if st, err := os.Lstat(filepath.Join(dir, n)); err != nil || !st.Mode().IsRegular() {
					t.Fatalf("%s: said written, isn't: %v", n, err)
				}
			}
		}
	})
}

package push

import (
	"archive/tar"
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

type entry struct {
	name, body, link string
	typ              byte
	format           tar.Format
}

func stream(t testing.TB, es ...entry) []byte {
	var b bytes.Buffer
	w := tar.NewWriter(&b)
	for _, e := range es {
		h := &tar.Header{Name: e.name, Typeflag: e.typ, Mode: 0o600, Linkname: e.link, ModTime: time.Unix(1, 0), Format: e.format}
		if e.typ == 0 {
			h.Typeflag = tar.TypeReg
		}
		if h.Typeflag == tar.TypeReg {
			h.Size = int64(len(e.body))
		}
		if err := w.WriteHeader(h); err != nil {
			t.Fatal(err)
		}
		if h.Size > 0 {
			w.Write([]byte(e.body))
		}
	}
	w.Close()
	return b.Bytes()
}

func file(n, b string) entry { return entry{name: n, body: b} }

func TestReceive(t *testing.T) {
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "old.html"), []byte("old"), 0o644)
	long := strings.Repeat("d/", 60) + "page.html" // over 100 bytes: a GNU or PAX long name
	files, err := Receive(bytes.NewReader(stream(t,
		file("./index.html", "<p>home"),
		entry{name: "proposals/", typ: tar.TypeDir},
		file("proposals/a b.html", "<p>a"),
		file("images/p/x.png", "PNG"),
		file("old.html", "new"),
		entry{name: long, body: "deep", format: tar.FormatGNU},
		entry{name: "pax/" + long, body: "deep", format: tar.FormatPAX},
	)), dir, Default)
	if err != nil {
		t.Fatal(err)
	}
	if len(files) != 6 {
		t.Fatalf("files %v", files)
	}
	for n, want := range map[string]string{"index.html": "<p>home", "proposals/a b.html": "<p>a", "images/p/x.png": "PNG", "old.html": "new", long: "deep", "pax/" + long: "deep"} {
		b, err := os.ReadFile(filepath.Join(dir, n))
		if err != nil || string(b) != want {
			t.Errorf("%s: %q %v", n, b, err)
		}
		st, _ := os.Stat(filepath.Join(dir, n))
		if st.Mode().Perm() != 0o644 {
			t.Errorf("%s: mode %v", n, st.Mode())
		}
	}
	if st, _ := os.Stat(filepath.Join(dir, "images/p")); st.Mode().Perm() != 0o755 {
		t.Errorf("folder mode %v", st.Mode())
	}
	// an empty push (no change): two zero blocks
	if f, err := Receive(bytes.NewReader(make([]byte, 1024)), dir, Default); err != nil || len(f) != 0 {
		t.Errorf("empty push: %v %v", f, err)
	}
}

// each refused whole, nothing written outside dir
func TestRefusals(t *testing.T) {
	small := Limits{Total: 100, File: 50, Entries: 3}
	cases := map[string]struct {
		s   []byte
		lim Limits
	}{
		"symlink":           {stream(t, entry{name: "a.html", typ: tar.TypeSymlink, link: "/etc/passwd"}), Default},
		"hardlink":          {stream(t, file("a", "x"), entry{name: "b.html", typ: tar.TypeLink, link: "a"}), Default},
		"char device":       {stream(t, entry{name: "a", typ: tar.TypeChar}), Default},
		"fifo":              {stream(t, entry{name: "a", typ: tar.TypeFifo}), Default},
		"dotdot":            {stream(t, file("../escaped", "x")), Default},
		"dotdot inside":     {stream(t, file("a/../../escaped", "x")), Default},
		"absolute":          {stream(t, file("/tmp/escaped", "x")), Default},
		"dot step":          {stream(t, file("a/./b", "x")), Default},
		"empty step":        {stream(t, file("a//b", "x")), Default},
		"only a dot":        {stream(t, entry{name: "./", typ: tar.TypeDir}), Default},
		"newline":           {stream(t, file("a\nb.html", "x")), Default},
		"backslash":         {stream(t, file(`a\..\b`, "x")), Default},
		"twice":             {stream(t, file("a", "x"), file("a", "y")), Default},
		"twice, ./ and not": {stream(t, file("a", "x"), file("./a", "y")), Default},
		"file then its dir": {stream(t, file("a", "x"), file("a/b", "y")), Default},
		"dir then its file": {stream(t, file("a/b", "x"), file("a", "y")), Default},
		"a file too big":    {stream(t, file("a", strings.Repeat("x", 51))), small},
		"too big in all":    {stream(t, file("a", strings.Repeat("x", 50)), file("b", strings.Repeat("x", 50)), file("c", "x")), small},
		"too many entries":  {stream(t, file("a", ""), file("b", ""), file("c", ""), file("d", "")), small},
		"cut short":         {stream(t, file("a", strings.Repeat("x", 600)))[:700], Default},
		"not tar":           {[]byte("<html>not a tar</html>" + strings.Repeat(" ", 600)), Default},
		"a name over 255":   {stream(t, entry{name: strings.Repeat("x", 256), body: "x", format: tar.FormatPAX}), Default},
	}
	for name, c := range cases {
		t.Run(name, func(t *testing.T) {
			root := t.TempDir()
			dir := filepath.Join(root, "staging")
			os.Mkdir(dir, 0o755)
			if _, err := Receive(bytes.NewReader(c.s), dir, c.lim); err == nil {
				t.Errorf("accepted")
			}
			filepath.Walk(root, func(p string, i os.FileInfo, err error) error {
				if p != root && !strings.HasPrefix(p, dir+string(filepath.Separator)) && p != dir {
					t.Errorf("written outside: %s", p)
				}
				if i != nil && i.Mode()&os.ModeSymlink != 0 {
					t.Errorf("a symlink: %s", p)
				}
				return nil
			})
		})
	}
}

// a symlink already in the folder (none should be: the gate's copy makes none) is never followed
func TestNoFollow(t *testing.T) {
	root := t.TempDir()
	dir, out := filepath.Join(root, "staging"), filepath.Join(root, "out")
	os.Mkdir(dir, 0o755)
	os.Mkdir(out, 0o755)
	os.Symlink(out, filepath.Join(dir, "link"))
	os.WriteFile(filepath.Join(out, "f"), []byte("keep"), 0o644)
	os.Symlink(filepath.Join(out, "f"), filepath.Join(dir, "f"))
	for _, s := range [][]byte{stream(t, file("link/x", "y")), stream(t, file("f", "y"))} {
		if _, err := Receive(bytes.NewReader(s), dir, Default); err == nil {
			t.Errorf("accepted a push through a symlink")
		}
	}
	if es, _ := os.ReadDir(out); len(es) != 1 {
		t.Errorf("written through a symlink: %v", es)
	}
	if b, _ := os.ReadFile(filepath.Join(out, "f")); string(b) != "keep" {
		t.Errorf("a file written through a symlink: %q", b)
	}
}

// a file another folder shares (a hard link) is replaced, never written through
func TestNewInode(t *testing.T) {
	root := t.TempDir()
	dir := filepath.Join(root, "staging")
	os.Mkdir(dir, 0o755)
	os.WriteFile(filepath.Join(root, "live"), []byte("live"), 0o644)
	os.Link(filepath.Join(root, "live"), filepath.Join(dir, "a"))
	if _, err := Receive(bytes.NewReader(stream(t, file("a", "pushed"))), dir, Default); err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(filepath.Join(root, "live")); string(b) != "live" {
		t.Errorf("the other copy changed: %q", b)
	}
}

func TestCopy(t *testing.T) {
	root := t.TempDir()
	src, dst := filepath.Join(root, "src"), filepath.Join(root, "dst")
	for _, d := range []string{src, dst, filepath.Join(src, "p"), filepath.Join(dst, "gone"), filepath.Join(dst, "swap")} {
		os.MkdirAll(d, 0o700)
	}
	put := func(p, s string, mt int64) {
		os.WriteFile(p, []byte(s), 0o600)
		os.Chtimes(p, time.Unix(mt, 0), time.Unix(mt, 0))
	}
	put(filepath.Join(src, "same"), "aaa", 100)
	put(filepath.Join(dst, "same"), "bbb", 100) // the same size and time: left as it is (rsync's quick check)
	put(filepath.Join(src, "changed"), "new", 200)
	put(filepath.Join(dst, "changed"), "old", 100)
	put(filepath.Join(src, "p", "new"), "n", 300)
	put(filepath.Join(src, "swap"), "file now", 400)
	put(filepath.Join(dst, "swap", "in"), "a folder with something in it", 1)
	put(filepath.Join(dst, "extra"), "x", 1)
	put(filepath.Join(src, "resent"), "same bytes", 500) // sent again, another time: not rewritten
	put(filepath.Join(dst, "resent"), "same bytes", 100)
	ino := func(p string) uint64 { st, _ := os.Stat(p); return st.Sys().(*syscall.Stat_t).Ino }
	before := ino(filepath.Join(dst, "resent"))
	if err := Copy(src, dst, false); err == nil {
		t.Errorf("without --delete: a file in a folder's place copied")
	}
	if err := Copy(src, dst, true); err != nil {
		t.Fatal(err)
	}
	for n, want := range map[string]string{"same": "bbb", "changed": "new", "p/new": "n", "swap": "file now"} {
		b, _ := os.ReadFile(filepath.Join(dst, n))
		st, _ := os.Stat(filepath.Join(dst, n))
		if string(b) != want || st.Mode().Perm() != 0o644 {
			t.Errorf("%s: %q %v", n, b, st.Mode())
		}
	}
	if st, _ := os.Stat(filepath.Join(dst, "p", "new")); st.ModTime().Unix() != 300 {
		t.Errorf("time not kept: %v", st.ModTime())
	}
	if st, _ := os.Stat(filepath.Join(dst, "p")); st.Mode().Perm() != 0o755 {
		t.Errorf("folder mode %v", st.Mode())
	}
	if st, _ := os.Stat(filepath.Join(dst, "resent")); ino(filepath.Join(dst, "resent")) != before || st.ModTime().Unix() != 500 {
		t.Errorf("the same bytes rewritten, or its time not src's")
	}
	for _, n := range []string{"extra", "gone"} {
		if _, err := os.Lstat(filepath.Join(dst, n)); err == nil {
			t.Errorf("%s left", n)
		}
	}
	os.Symlink("/etc/passwd", filepath.Join(src, "link"))
	if err := Copy(src, dst, true); err == nil {
		t.Errorf("a symlink copied")
	}
	os.Remove(filepath.Join(src, "link"))
	syscall.Mkfifo(filepath.Join(src, "fifo"), 0o600)
	if err := Copy(src, dst, true); err == nil {
		t.Errorf("a FIFO copied")
	}
}

// review 10's M-1: a folder entry makes nothing; a file takes an empty folder's place (in the
// push and in the copy to the live site), a folder with something in it still refuses
func TestFoldersOnlyForFiles(t *testing.T) {
	root := t.TempDir()
	live, staging := filepath.Join(root, "live"), filepath.Join(root, "staging")
	os.MkdirAll(filepath.Join(live, "proposals", "next.html"), 0o755) // left live by an older gate
	os.MkdirAll(filepath.Join(live, "proposals", "full.html"), 0o755)
	os.WriteFile(filepath.Join(live, "proposals", "full.html", "x"), []byte("x"), 0o644)
	if err := Copy(live, staging, true); err != nil {
		t.Fatal(err)
	}
	if _, err := Receive(bytes.NewReader(stream(t, entry{name: "explore/tag/x/", typ: tar.TypeDir})), staging, Default); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(staging, "explore")); err == nil {
		t.Errorf("a folder entry made a folder")
	}
	if _, err := Receive(bytes.NewReader(stream(t, file("proposals/next.html", "<p>new"))), staging, Default); err != nil {
		t.Fatalf("a page where an empty folder was: %v", err)
	}
	if err := Copy(staging, live, false); err != nil {
		t.Fatalf("copied live: %v", err)
	}
	if b, err := os.ReadFile(filepath.Join(live, "proposals", "next.html")); err != nil || string(b) != "<p>new" {
		t.Errorf("the page isn't live: %q %v", b, err)
	}
	if _, err := Receive(bytes.NewReader(stream(t, file("proposals/full.html", "<p>"))), staging, Default); err == nil {
		t.Errorf("a file put where a folder holds something")
	}
}

// review 10's L-3: a temp file a killed copy left is removed by the next, never copied, and no
// push may name one
func TestTempLeftOver(t *testing.T) {
	root := t.TempDir()
	src, dst := filepath.Join(root, "src"), filepath.Join(root, "dst")
	os.MkdirAll(filepath.Join(src, "p"), 0o755)
	os.MkdirAll(filepath.Join(dst, "p"), 0o755)
	os.WriteFile(filepath.Join(src, "p", ".ccs-push-111"), []byte("half"), 0o600)
	os.WriteFile(filepath.Join(dst, "p", ".ccs-push-222"), []byte("half a page"), 0o600)
	os.WriteFile(filepath.Join(src, "p", "a.html"), []byte("<p>"), 0o644)
	if err := Copy(src, dst, false); err != nil {
		t.Fatal(err)
	}
	for _, n := range []string{".ccs-push-111", ".ccs-push-222"} {
		if _, err := os.Lstat(filepath.Join(dst, "p", n)); err == nil {
			t.Errorf("%s left in the copy", n)
		}
	}
	if _, err := Receive(bytes.NewReader(stream(t, file("p/.ccs-push-9", "x"))), dst, Default); err == nil {
		t.Errorf("a push named a temp file")
	}
}

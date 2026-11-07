package push

import (
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

const data = `{"state": {}, "funds": {}, "ideas": []}`

// the push: site-data.json, or nothing (the heartbeat); anything else, or too much, refused
func TestData(t *testing.T) {
	for name, c := range map[string]struct {
		in   string
		got  bool
		fail bool
	}{
		"site-data.json":               {data, true, false},
		"spaces before it":             {"\n  " + data, true, false},
		"nothing (the heartbeat)":      {"", false, false},
		"an older backend's empty tar": {strings.Repeat("\x00", 1024), false, false},
		"an older backend's tar":       {"site-data.json\x00\x00\x00" + strings.Repeat("\x00", 1000), false, true},
		"a page":                       {"<p>Donate here</p>", false, true},
		"over the limit":               {"{" + strings.Repeat(" ", 3000), false, true},
	} {
		dir := t.TempDir()
		got, err := Data(strings.NewReader(c.in), dir, 2048)
		if got != c.got || (err != nil) != c.fail {
			t.Errorf("%s: %v %v", name, got, err)
		}
		b, rerr := os.ReadFile(filepath.Join(dir, "site-data.json"))
		if c.got && (rerr != nil || string(b) != c.in) || !c.got && rerr == nil {
			t.Errorf("%s: written %q %v", name, b, rerr)
		}
	}
}

// what staging holds at site-data.json, a link or a file another folder shares, is replaced, never
// written through
func TestDataNoFollow(t *testing.T) {
	root := t.TempDir()
	dir := filepath.Join(root, "staging")
	os.Mkdir(dir, 0o755)
	os.WriteFile(filepath.Join(root, "passwd"), []byte("keep"), 0o644)
	os.Symlink(filepath.Join(root, "passwd"), filepath.Join(dir, "site-data.json"))
	if _, err := Data(strings.NewReader(data), dir, 1<<20); err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(filepath.Join(root, "passwd")); string(b) != "keep" {
		t.Errorf("written through a link: %q", b)
	}
	if st, _ := os.Lstat(filepath.Join(dir, "site-data.json")); st == nil || !st.Mode().IsRegular() {
		t.Errorf("site-data.json not a plain file")
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
// review 10's M-1: an empty folder an older gate left live where a page goes gives way to it
func TestFoldersOnlyForFiles(t *testing.T) {
	root := t.TempDir()
	live, staging := filepath.Join(root, "live"), filepath.Join(root, "staging")
	os.MkdirAll(filepath.Join(live, "proposals", "next.html"), 0o755)
	os.MkdirAll(filepath.Join(live, "proposals", "full.html"), 0o755)
	os.WriteFile(filepath.Join(live, "proposals", "full.html", "x"), []byte("x"), 0o644)
	os.MkdirAll(filepath.Join(staging, "proposals"), 0o755)
	os.WriteFile(filepath.Join(staging, "proposals", "next.html"), []byte("<p>new"), 0o644)
	if err := Copy(staging, live, false); err != nil {
		t.Fatalf("copied live: %v", err)
	}
	if b, err := os.ReadFile(filepath.Join(live, "proposals", "next.html")); err != nil || string(b) != "<p>new" {
		t.Errorf("the page isn't live: %q %v", b, err)
	}
	os.WriteFile(filepath.Join(staging, "proposals", "full.html"), []byte("<p>"), 0o644)
	if err := Copy(staging, live, false); err == nil {
		t.Errorf("a file put where a folder holds something")
	}
}

// review 10's L-3: a temp file a killed copy left is removed by the next, never copied
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
}

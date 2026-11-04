package gate

import (
	"bytes"
	"crypto/sha1"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func write(t *testing.T, p, s string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(s), 0o644); err != nil {
		t.Fatal(err)
	}
}

func hexsum(s string) string { h := sha256.Sum256([]byte(s)); return hex.EncodeToString(h[:]) }

// a gate's folders: staging, live, the config (list, allowed, sums); its checks' program missing,
// so no check that runs as its own process passes anything
func setup(t *testing.T) (Config, string) {
	d := t.TempDir()
	c := Config{Staging: d + "/staging", Live: d + "/live", List: d + "/conf/subaddresses.txt",
		Allowed: d + "/conf/allowed", DesignSums: d + "/conf/design.sha256", Designs: d + "/design",
		FeedAwk: d + "/feed.awk", Site: "https://ccs.test", Held: d + "/held", Self: d + "/no-such-program"}
	addr := "4" + strings.Repeat("A", 94)
	write(t, c.List, "0 "+addr+"\n")
	write(t, c.List+".qr.sha256", hexsum("qr png")+"  "+addr+".png\n")
	write(t, c.DesignSums, hexsum("a {}")+"  ./assets/style.css\n")
	os.MkdirAll(c.Staging, 0o755)
	os.MkdirAll(c.Live, 0o755)
	return c, addr
}

func verdicts(t *testing.T, c Config) map[string]string {
	var b bytes.Buffer
	if _, _, err := Run(c, &b); err != nil {
		t.Fatal(err)
	}
	m := map[string]string{}
	for _, l := range strings.Split(strings.TrimSpace(b.String()), "\n") {
		if f, why, ok := strings.Cut(l, "\t"); ok {
			rel, _ := filepath.Rel(c.Staging, f)
			m[rel] = why
		}
	}
	return m
}

// each file by its bytes: the design's, the list's QR codes and files, the repository's images
func TestFiles(t *testing.T) {
	c, addr := setup(t)
	img := "GIF89a..."
	h := sha1.New()
	fmt.Fprintf(h, "blob %d\x00%s", len(img), img)
	write(t, filepath.Join(filepath.Dir(c.Staging), "images.txt"), hex.EncodeToString(h.Sum(nil))+" images/p/a.gif\n")
	c.Images = filepath.Join(filepath.Dir(c.Staging), "images.txt")
	write(t, filepath.Dir(c.List)+"/subaddresses.txt.asc", "sig")
	for rel, s := range map[string]string{
		"assets/style.css": "a {}", "assets/other.css": "b {}",
		"qr/" + addr + ".png": "qr png", "qr/" + strings.Replace(addr, "A", "B", 1) + ".png": "qr png", "qr/x.png": "qr png",
		"images/p/a.gif": img, "images/p/b.gif": img, "images/p/a.svg": img,
		"subaddresses.txt.asc": "sig", "subaddresses.txt.key.asc": "key",
	} {
		write(t, filepath.Join(c.Staging, rel), s)
	}
	write(t, filepath.Join(c.Live, "unchanged.bin"), "x")
	write(t, filepath.Join(c.Staging, "unchanged.bin"), "x")
	got := verdicts(t, c)
	for rel, held := range map[string]bool{
		"assets/style.css": false, "assets/other.css": true, "qr/" + addr + ".png": false,
		"qr/" + strings.Replace(addr, "A", "B", 1) + ".png": true, "qr/x.png": true,
		"images/p/a.gif": false, "images/p/b.gif": true, "images/p/a.svg": true,
		"subaddresses.txt.asc": false, "subaddresses.txt.key.asc": true, "unchanged.bin": false,
	} {
		if _, h := got[rel]; h != held {
			t.Errorf("%s: held %v (%q)", rel, h, got[rel])
		}
	}
	// the repository not read: no new image goes live
	c.Images = ""
	if got := verdicts(t, c); !strings.Contains(got["images/p/a.gif"], "could not be read") {
		t.Errorf("an image, the repository unread: %q", got["images/p/a.gif"])
	}
}

// nothing goes live for want of a complaint: a page, JSON or feed whose checks can't run is held,
// and so is one unchanged but held back last time; one unchanged, not
func TestDefaultDeny(t *testing.T) {
	c, _ := setup(t)
	for _, rel := range []string{"index.html", "projects.json", "feed.xml", "old.html", "same.html"} {
		write(t, filepath.Join(c.Staging, rel), "<p>x</p>\n")
	}
	write(t, filepath.Join(c.Live, "old.html"), "<p>x</p>\n")
	write(t, filepath.Join(c.Live, "same.html"), "<p>x</p>\n")
	write(t, c.Held, "old.html\n")
	got := verdicts(t, c)
	for _, rel := range []string{"index.html", "projects.json", "feed.xml", "old.html"} {
		if !strings.HasPrefix(got[rel], "!") {
			t.Errorf("%s: %q, want held", rel, got[rel])
		}
	}
	if w, ok := got["same.html"]; ok {
		t.Errorf("same.html (as live, not held last time): held, %q", w)
	}
	// every one checked again: same.html too
	c.Full = true
	if got := verdicts(t, c); !strings.HasPrefix(got["same.html"], "!") {
		t.Errorf("same.html, all checked: %q", got["same.html"])
	}
}

// a list with no address: an error, never a gate that passes every address
func TestEmptyList(t *testing.T) {
	c, _ := setup(t)
	write(t, c.List, "\n")
	var b bytes.Buffer
	if _, _, err := Run(c, &b); err == nil {
		t.Errorf("an empty list: no error")
	}
}

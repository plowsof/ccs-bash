package gate

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
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

// Two real addresses (valid by Monero's checksum, as the scan reads them): the list's, and another
const (
	fund    = "44AFFq5kSiGBoZ4NMDwYtN18obc8AemS33DBLWs3H7otXft3XjrpDtQGv7SqSsaBYBb98uNbr2VBBEt7f2wfn3RVGQBEP3A"
	foreign = "8BG2dKUw7eWT2u7g7z9Em4UhXF8H6Rdmm65TjzFKJ3afB7vhzb5Dev379oNQTnK7WoFzfLovEuNr45BwR114jKCW3QK3uRw"
)

func hexsum(s string) string { h := sha256.Sum256([]byte(s)); return hex.EncodeToString(h[:]) }

// A built site and the config (list, its QR codes' sums, allowed)
func setup(t *testing.T) (Config, string) {
	d := t.TempDir()
	c := Config{Site: d + "/site", List: d + "/conf/subaddresses.txt", Allowed: d + "/conf/allowed"}
	addr := fund
	write(t, c.List, "0 "+addr+"\n")
	write(t, c.List+".qr.sha256", hexsum("qr png")+"  "+addr+".png\n")
	os.MkdirAll(c.Site, 0o755)
	return c, addr
}

func verdicts(t *testing.T, c Config) map[string]string {
	var b bytes.Buffer
	if _, err := Run(c, &b); err != nil {
		t.Fatal(err)
	}
	m := map[string]string{}
	for _, l := range strings.Split(strings.TrimSpace(b.String()), "\n") {
		if f, why, ok := strings.Cut(l, "\t"); ok {
			rel, _ := filepath.Rel(c.Site, f)
			m[rel] = why
		}
	}
	return m
}

// QR codes checked by their sums; a page's address must be the list's; the feed has none; a file that isn't plain
func TestRun(t *testing.T) {
	c, addr := setup(t)
	other := foreign
	for rel, s := range map[string]string{
		"qr/" + addr + ".png": "qr png", "qr/" + other + ".png": "qr png", "qr/x.png": "qr png",
		"assets/style.css": "a {}", "images/p/a.gif": "GIF89a",
		"index.html": "<p>" + addr + "</p>\n", "nul.html": "<p>x\x00</p>\n",
		"data.html": `<img src="data:image/png;base64,AAAA">` + "\n",
		"feed.xml":  "<rss>" + addr + "</rss>\n", "bad.json": "{\n",
	} {
		write(t, filepath.Join(c.Site, rel), s)
	}
	os.Symlink("index.html", filepath.Join(c.Site, "link.html"))
	got := verdicts(t, c)
	for rel, held := range map[string]bool{
		"qr/" + addr + ".png": false, "qr/" + other + ".png": true, "qr/x.png": true,
		"assets/style.css": false, "images/p/a.gif": false, "index.html": false, "nul.html": true,
		"data.html": true, "feed.xml": true, "bad.json": true, "link.html": true,
	} {
		if _, h := got[rel]; h != held {
			t.Errorf("%s: held %v (%q)", rel, h, got[rel])
		}
	}
	// An address neither on the list nor allowed, then allowed
	write(t, filepath.Join(c.Site, "index.html"), "<p>"+other+"</p>\n")
	if got := verdicts(t, c); got["index.html"] != other {
		t.Errorf("a foreign address: %q", got["index.html"])
	}
	write(t, c.Allowed, "# a comment\n"+other+"\n")
	if got := verdicts(t, c); got["index.html"] != "" {
		t.Errorf("an allowed address: %q", got["index.html"])
	}
}

// A list with no address is an error, never a gate that passes every address
func TestEmptyList(t *testing.T) {
	c, _ := setup(t)
	write(t, c.List, "\n")
	var b bytes.Buffer
	if _, err := Run(c, &b); err == nil {
		t.Errorf("an empty list: no error")
	}
}

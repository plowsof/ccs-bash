package pages

import (
	"bufio"
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// the values as ccs-bash and ccs-front-bash make them: each "want" from jq (1.6 and 1.7 alike)
// with ccs-front-bash's lib/common.jq, and ccs-bash's to_atomic and xmr4 (lib/wallet.sh)
func TestFrontValues(t *testing.T) {
	for _, c := range []struct{ tag, slug, color, href string }{
		{"Abandoned", "abandoned", "tag-7", "/explore/tag/abandoned/"},
		{"Available to pick up", "available-to-pick-up", "tag-0", "/explore/tag/available-to-pick-up/"},
		{"Ünïcode Tag!", "Ünïcode-tag", "tag-3", "/explore/tag/%C3%9Cn%C3%AFcode-tag/"},
		{"C++ &amp; Rust", "c-rust", "tag-1", "/explore/tag/c-rust/"},
		{"日本語 タグ", "日本語-タグ", "tag-5", "/explore/tag/%E6%97%A5%E6%9C%AC%E8%AA%9E-%E3%82%BF%E3%82%B0/"},
		{"  --x--  ", "x", "tag-0", "/explore/tag/x/"},
		{"R&amp;D", "r-d", "tag-1", "/explore/tag/r-d/"},
		{"a&#39;b", "a-b", "tag-6", "/explore/tag/a-b/"},
		{"123", "123", "tag-2", "/explore/tag/123/"},
	} {
		s := slug(c.tag)
		if s != c.slug || color(s) != c.color || "/explore/tag/"+uri(s)+"/" != c.href {
			t.Errorf("%q: %q %q %q", c.tag, s, color(s), uri(s))
		}
	}
	for in, want := range map[string]string{"10": "10", "10.5": "10.5", "12.34567": "12.3456", "0.00009": "0",
		"1500": "1500", "7.10": "7.1", "0010.2500": "10.25", "99999999": ""} {
		if got := goal(in); got != want {
			t.Errorf("goal(%q): %q, want %q", in, got, want)
		}
	}
	for in, want := range map[string]string{"2021 6 25": "June 25, 2021", "2024 2 30": "March 1, 2024",
		"2026 10 22": "October 22, 2026", "1969 12 31": "", "2021 1 1": "January 1, 2021", "": ""} {
		if got := day(in); got != want {
			t.Errorf("day(%q): %q, want %q", in, got, want)
		}
	}
}

// frontmatter.awk's lines: escaped, bidi controls out, tags by slug (the first spelling)
func TestReadFronts(t *testing.T) {
	f := filepath.Join(t.TempDir(), "fronts.tsv")
	line := "p.md\tfr\tA <b> & ‮name\tsome'one\t2026 10 22\t10.50\thttps://forge.test/p/-/merge_requests/1\t3\t1\tRust\x1frust!\x1f!!\x1fC++\n"
	if err := os.WriteFile(f, []byte(line+"bad line\n"), 0o644); err == nil {
		if _, err := readFronts(f); err == nil {
			t.Errorf("a line that isn't frontmatter.awk's: read")
		}
	}
	if err := os.WriteFile(f, []byte(line), 0o644); err != nil {
		t.Fatal(err)
	}
	fs, err := readFronts(f + ":" + f + ":")
	if err != nil {
		t.Fatal(err)
	}
	p := fs["p"]
	if len(p) != 1 {
		t.Fatalf("%d fronts (the same from two commits: once)", len(p))
	}
	g := p[0]
	if g.layout != "fr" || g.name != "A &lt;b&gt; &amp; name" || g.author != "some&#39;one" || g.date != "October 22, 2026" ||
		g.amount != "10.5" || g.gitlab != "https://forge.test/p/-/merge_requests/1" || g.milestones != 3 || g.done != 1 {
		t.Errorf("%+v", *g)
	}
	if len(g.tags) != 2 || g.tags[0].tag != "Rust" || g.tags[0].slug != "rust" || g.tags[1].tag != "C++" || g.tags[1].slug != "c" {
		t.Errorf("tags: %+v", g.tags)
	}
}

// litq: an apostrophe as either escape, nothing else loosened
func TestLitq(t *testing.T) {
	for _, c := range []struct {
		s, want string
		end     int
	}{
		{"it&#39;s", "it&#39;s", 8},
		{"it&apos;s", "it&#39;s", 9},
		{"it's", "it&#39;s", -1},
		{"its", "it&#39;s", -1},
	} {
		if e := litq(newCtx([]rune(c.s)), 0, c.want); e != c.end {
			t.Errorf("%q against %q: %d, want %d", c.s, c.want, e, c.end)
		}
	}
}

// a proposal's page: its name, author and tags its front matter's (a small design: a page part,
// its label-link and a donation box with no address)
func TestFrontPage(t *testing.T) {
	d := t.TempDir()
	for name, text := range map[string]string{
		"parts/proposal-fr.html":  "<h1>{{name}}</h1><p>{{author}} {{date}}</p><p>{{tag_links}}</p>\n<!-- ccs:donate -->\n<!-- /ccs:donate -->\n{{body}}\n</html>",
		"parts/proposal-wip.html": "<h1>{{name}}</h1>{{body}}\n</html>", "parts/proposal-cp.html": "<h1>{{name}}</h1>{{body}}\n</html>",
		"parts/label-link.html": "<a class=\"label {{color}}\" href=\"{{href}}\">{{tag}}</a>\n",
		"parts/label.html":      "<span class=\"label {{color}}\">{{tag}}</span>\n",
		"parts/donate.html":     "<p>{{raised}} of {{amount}}</p>\n", "parts/segment-done.html": "<i></i>\n", "parts/segment-todo.html": "<b></b>\n",
		"parts/verify-link.html": "\n",
	} {
		if err := os.MkdirAll(filepath.Dir(filepath.Join(d, name)), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(d, name), []byte(text), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	tmp := t.TempDir()
	bodies, fronts := filepath.Join(tmp, "b.jsonl"), filepath.Join(tmp, "f.tsv")
	os.WriteFile(bodies, []byte(`{"file":"p","body":"<p>Text</p>","milestones":[],"payouts":[]}`+"\n"), 0o644)
	os.WriteFile(fronts, []byte("p.md\tfr\tA proposal\tsomeone\t2026 10 22\t10\t\t1\t0\tRust\x1fC++\n"), 0o644)
	c, err := New(d, bodies, testList(t), "", "repo.example/ccs", "", fronts, "")
	if err != nil {
		t.Fatal(err)
	}
	rust := `<a class="label ` + color("rust") + `" href="../explore/tag/rust/">Rust</a>`
	cpp := `<a class="label ` + color("c") + `" href="../explore/tag/c/">C++</a>`
	links := rust + cpp
	good := "<h1>A proposal</h1><p>someone October 22, 2026</p><p>" + links + "</p>\n<!-- ccs:donate -->\n<p>1.5 of 10</p>\n<!-- /ccs:donate -->\n<p>Text</p>\n</html>\n"
	site := t.TempDir()
	os.MkdirAll(filepath.Join(site, "proposals"), 0o755)
	for name, c2 := range map[string]struct {
		page string
		ok   bool
	}{
		"as its front matter":       {good, true},
		"renamed":                   {strings.Replace(good, "<h1>A proposal", "<h1>Another", 1), false},
		"another author":            {strings.Replace(good, "someone", "someone else", 1), false},
		"another date":              {strings.Replace(good, "October 22", "October 23", 1), false},
		"another goal":              {strings.Replace(good, "of 10", "of 20", 1), false},
		"a tag left out":            {strings.Replace(good, cpp, "", 1), false},
		"a tag made up":             {strings.Replace(good, ">Rust<", ">Go<", 1), false},
		"its tags in another order": {strings.Replace(good, rust+cpp, cpp+rust, 1), false},
	} {
		os.WriteFile(filepath.Join(site, "proposals", "p.html"), []byte(c2.page), 0o644)
		var b bytes.Buffer
		w := bufio.NewWriter(&b)
		if err := c.Run(site, strings.NewReader("proposals/p.html\x00"), w); err != nil {
			t.Fatal(err)
		}
		if got := strings.HasSuffix(b.String(), "\t=ok\n"); got != c2.ok {
			t.Errorf("%s: %q", name, b.String())
		}
	}
}

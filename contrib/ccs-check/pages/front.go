package pages

// A proposal's front matter, as the proposals repository has it: what a page and its cards say of
// the proposal (its name, author, date, goal, stage, milestone counts, link and tags) must be
// that, as ccs-bash (lib/site.jq) and ccs-front-bash (lib/common.jq) show it. Read from ccs-bash's
// own lib/frontmatter.awk run on each fetched commit (ccs-receive's bodies), not parsed here.
// What only the backend knows (raised, percentage, contributors, pending, its own dates) is not
// in it.

import (
	"errors"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"
	"unicode"
)

// front: one proposal's values, as a page shows them (escaped); jname and jauthor as
// projects.json has them (site.jq's project: its bidi controls kept)
type front struct {
	layout, name, author, date, amount, gitlab string
	jname, jauthor                             string
	milestones, done                           int
	tags                                       []ftag
}

// ftag: a tag as common.jq's tag_list has it
type ftag struct{ tag, slug, color string }

// nobidi: site.jq's: the bidi controls taken out
func nobidi(s string) string {
	return strings.Map(func(r rune) rune {
		if r >= 0x202a && r <= 0x202e || r >= 0x2066 && r <= 0x2069 {
			return -1
		}
		return r
	}, s)
}

// unesc: common.jq's unescape
func unesc(s string) string {
	return strings.NewReplacer("&#39;", "'", "&apos;", "'", "&quot;", "\"", "&gt;", ">", "&lt;", "<", "&amp;", "&").Replace(s)
}

// slug: common.jq's: letters (any script) and digits, ASCII lower case, dashes between
func slug(tag string) string {
	var b strings.Builder
	dash := false
	for _, r := range unesc(tag) {
		if r >= 'A' && r <= 'Z' {
			r += 'a' - 'A'
		}
		if unicode.IsLetter(r) || unicode.IsNumber(r) {
			if dash && b.Len() > 0 {
				b.WriteByte('-')
			}
			dash = false
			b.WriteRune(r)
		} else {
			dash = true
		}
	}
	return b.String()
}

// color: common.jq's tag_color
func color(slug string) string {
	v := 0
	for _, r := range slug {
		v = (v*31 + int(r)) % 1000003
	}
	return fmt.Sprintf("tag-%d", v%8)
}

// uri: jq's @uri (all but A-Za-z0-9 -_.~ as %XX)
func uri(s string) string {
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || strings.IndexByte("-_.~", c) >= 0 {
			b.WriteByte(c)
		} else {
			fmt.Fprintf(&b, "%%%02X", c)
		}
	}
	return b.String()
}

// goal: an amount as the page shows it: ccs-bash's to_atomic then xmr4 (4 decimals, cut off),
// common.jq's trim0; "" for one bash's arithmetic would wrap (over 9,223,372 XMR: not checked)
func goal(a string) string {
	whole, frac, _ := strings.Cut(a, ".")
	w, err := strconv.ParseInt(whole, 10, 64)
	if err != nil || w > 9223371 {
		return ""
	}
	frac = strings.TrimRight((frac + "0000")[:4], "0")
	if frac == "" {
		return strconv.FormatInt(w, 10)
	}
	return strconv.FormatInt(w, 10) + "." + frac
}

// day: "year month day" as site.jq's date shows it (mktime, then strftime "%B %-d, %Y"); "" for
// none, or one not after 1970
func day(ymd string) string {
	f := strings.Fields(ymd)
	if len(f) != 3 {
		return ""
	}
	var n [3]int
	for i, s := range f {
		v, err := strconv.Atoi(s)
		if err != nil {
			return ""
		}
		n[i] = v
	}
	t := time.Date(n[0], time.Month(n[1]), n[2], 0, 0, 0, 0, time.UTC)
	if t.Unix() <= 0 {
		return ""
	}
	return t.Format("January 2, 2006")
}

// readFronts: frontmatter.awk's lines from each file (":"-separated, one a commit), by proposal
// (the file without .md): "file layout title author ymd amount gitlab_url milestones done tags"
func readFronts(files string) (map[string][]*front, error) {
	fs := map[string][]*front{}
	for _, f := range strings.Split(files, ":") {
		if f == "" {
			continue
		}
		if _, err := os.Stat(f); err != nil {
			continue
		}
		raw, err := os.ReadFile(f)
		if err != nil {
			return nil, err
		}
		// (bytes that aren't UTF-8 as jq reads them, U+FFFD: one proposal's title can't stop the
		// rest being read)
		for _, line := range strings.Split(strings.ToValidUTF8(string(raw), "\ufffd"), "\n") {
			if line == "" {
				continue
			}
			x := strings.Split(line, "\t")
			if len(x) != 10 || !strings.HasSuffix(x[0], ".md") {
				return nil, errors.New("a line of frontmatter.awk's that can't be read")
			}
			m, err1 := strconv.Atoi(x[7])
			d, err2 := strconv.Atoi(x[8])
			if err1 != nil || err2 != nil {
				return nil, errors.New("a line of frontmatter.awk's that can't be read")
			}
			p := &front{layout: x[1], name: esc(nobidi(x[2])), author: esc(nobidi(x[3])), date: day(x[4]),
				amount: goal(x[5]), milestones: m, done: d, jname: esc(x[2]), jauthor: esc(x[3])}
			if x[6] != "" {
				p.gitlab = esc(x[6])
			}
			// tag_list: escaped, by slug (none without one), the first spelling of each
			seen := map[string]bool{}
			if x[9] != "" {
				for _, g := range strings.Split(x[9], "\x1f") {
					tag := esc(nobidi(g))
					s := slug(tag)
					if s == "" || seen[s] {
						continue
					}
					seen[s] = true
					p.tags = append(p.tags, ftag{tag, s, color(s)})
				}
			}
			name := strings.TrimSuffix(x[0], ".md")
			dup := false
			for _, o := range fs[name] {
				dup = dup || fmt.Sprint(*o) == fmt.Sprint(*p)
			}
			if !dup {
				fs[name] = append(fs[name], p)
			}
		}
	}
	return fs, nil
}

// newest: the proposals in the first of frontmatter.awk's files (the newest commit fetched)
func newest(files string) map[string]bool {
	m := map[string]bool{}
	for _, f := range strings.Split(files, ":") {
		raw, err := os.ReadFile(f)
		if f == "" || err != nil {
			continue
		}
		for _, line := range strings.Split(string(raw), "\n") {
			if n, _, ok := strings.Cut(line, "\t"); ok && strings.HasSuffix(n, ".md") {
				m[strings.TrimSuffix(n, ".md")] = true
			}
		}
		break
	}
	return m
}

// litq: t at i, an apostrophe as either escape (jq @html writes &#39; or &apos;)
func litq(c *ctx, i int, t string) int {
	r := []rune(strings.ReplaceAll(t, "&apos;", "&#39;"))
	j := i
	for k := 0; k < len(r); {
		if k+5 <= len(r) && string(r[k:k+5]) == "&#39;" && j+6 <= len(c.s) && string(c.s[j:j+6]) == "&apos;" {
			k, j = k+5, j+6
			continue
		}
		if j >= len(c.s) || c.s[j] != r[k] {
			return -1
		}
		k, j = k+1, j+1
	}
	return j
}

// value: a slot whose value is the proposal's own (the page's, or its card's: card), one of
// its fronts' (a commit each); nothing matches when none is known
func (d *design) value(card bool, depth int, of func(*front, int) string) node {
	return func(c *ctx, i int, k func(int) bool) bool {
		fs := c.page
		if card {
			fs = c.card
		}
		for _, f := range fs {
			if e := litq(c, i, of(f, depth)); e >= 0 && k(e) {
				return true
			}
		}
		return false
	}
}

// labels: common.jq's labels (a card's) and tag_links (a page's, its links made relative)
func (d *design) labels(f *front, depth int, links bool) string {
	name := "label"
	if links {
		name = "label-link"
	}
	t, err := d.part(name)
	if err != nil {
		return "\x00" // (matches nothing)
	}
	var b strings.Builder
	for _, g := range f.tags {
		r, err := put(part(t), map[string]string{"tag": g.tag, "color": g.color, "href": "/explore/tag/" + uri(g.slug) + "/"})
		if err != nil {
			return "\x00"
		}
		b.WriteString(r)
	}
	if links {
		return rel(b.String(), depth)
	}
	return b.String()
}

// segs: common.jq's segments: a done part for each milestone done, the rest to do
func (d *design) segsOf(f *front) string {
	done, err1 := d.part("segment-done")
	todo, err2 := d.part("segment-todo")
	if err1 != nil || err2 != nil {
		return "\x00"
	}
	var b strings.Builder
	for i := 0; i < f.milestones; i++ {
		if i < f.done {
			b.WriteString(part(done))
		} else {
			b.WriteString(part(todo))
		}
	}
	return b.String()
}

// fromFront: the slots a proposal's front matter gives, on its page (card false) or its card
func (d *design) fromFront(s pats, card bool, depth int) {
	v := func(of func(*front, int) string) node { return d.value(card, depth, of) }
	s["name"] = v(func(f *front, _ int) string { return f.name })
	s["author"] = v(func(f *front, _ int) string { return f.author })
	s["date"] = v(func(f *front, _ int) string { return f.date })
	// the goal; one too large for bash's arithmetic (over 9,223,372 XMR) any amount
	s["amount"] = func(c *ctx, i int, k func(int) bool) bool {
		fs := c.page
		if card {
			fs = c.card
		}
		for _, f := range fs {
			if f.amount == "" {
				if XMR(c, i, k) {
					return true
				}
			} else if e := litq(c, i, f.amount); e >= 0 && k(e) {
				return true
			}
		}
		return false
	}
	s["milestones"] = v(func(f *front, _ int) string { return strconv.Itoa(f.milestones) })
	s["done"] = v(func(f *front, _ int) string { return strconv.Itoa(f.done) })
	s["segments"] = v(func(f *front, _ int) string { return d.segsOf(f) })
	if card {
		s["tags"] = v(func(f *front, _ int) string { return d.labels(f, depth, false) })
	} else {
		s["tag_links"] = v(func(f *front, depth int) string { return d.labels(f, depth, true) })
		// its own link when its front matter has one; else the backend's (proposals.csv)
		link := s["gitlab_url"]
		s["gitlab_url"] = func(c *ctx, i int, k func(int) bool) bool {
			for _, f := range c.page {
				if f.gitlab != "" {
					if e := litq(c, i, f.gitlab); e >= 0 && k(e) {
						return true
					}
				} else if link(c, i, k) {
					return true
				}
			}
			return false
		}
	}
}

// cardURL: a card's link to its proposal's page, that proposal's fronts (of this stage) then
// its card's (c.card) for the slots after it; none known, no match
func (d *design) cardURL(depth int, stage string) node {
	p := []rune(prefixOf(depth) + "proposals/")
	return func(c *ctx, i int, k func(int) bool) bool {
		if i+len(p) > len(c.s) || string(c.s[i:i+len(p)]) != string(p) {
			return false
		}
		j := i + len(p)
		return NAME(c, j, func(e int) bool {
			if e+5 > len(c.s) || string(c.s[e:e+5]) != ".html" {
				return false
			}
			var fs []*front
			for _, f := range d.c.fronts[unesc(string(c.s[j:e]))] {
				if f.layout == stage {
					fs = append(fs, f)
				}
			}
			if len(fs) == 0 {
				return false
			}
			old := c.card
			c.card = fs
			if k(e + 5) {
				return true
			}
			c.card = old
			return false
		})
	}
}

// anyTag: a tag some proposal has (its first spelling or another: the filters and a tag
// page's title); anySlug: the link to its tag page
func (d *design) anyTag() node {
	return func(c *ctx, i int, k func(int) bool) bool {
		for _, t := range d.c.spellings {
			if e := litq(c, i, t); e >= 0 && k(e) {
				return true
			}
		}
		return false
	}
}

func (d *design) anySlug(depth int) node {
	var ns []node
	for s := range d.c.slugs {
		ns = append(ns, lit(prefixOf(depth)+"explore/tag/"+uri(s)+"/"))
	}
	if len(ns) == 0 {
		return never
	}
	return alt(ns...)
}

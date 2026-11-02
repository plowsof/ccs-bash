// Package pages: each page must be one of the design's own, every region filled with the
// design's parts and every {{slot}} with a value of its kind, as ccs-front-bash fills them; a
// proposal's text, milestones and payouts exactly what markdown.awk makes of its file; a
// donation box one address of the signed list. ccs-receive's pages_py, in the same order, its
// regexes as match.go's nodes.
package pages

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"unicode/utf8"
)

// pyError: an exception of pages_py's, by the name its reason shows ("... (FileNotFoundError)")
type pyError struct{ name string }

func (e pyError) Error() string { return e.name }

// keyError: a part or slot the design has none of (pages_py's KeyError: str() quotes it)
type keyError struct{ key string }

func (e keyError) Error() string { return "'" + e.key + "'" }

// read: the file as UTF-8, or the exception pages_py's read would have raised
func read(p string) (string, error) {
	b, err := os.ReadFile(p)
	if err != nil {
		switch {
		case errors.Is(err, fs.ErrNotExist):
			return "", pyError{"FileNotFoundError"}
		case errors.Is(err, syscall.EISDIR):
			return "", pyError{"IsADirectoryError"}
		case errors.Is(err, fs.ErrPermission):
			return "", pyError{"PermissionError"}
		}
		return "", pyError{"OSError"}
	}
	if !utf8.Valid(b) {
		return "", pyError{"UnicodeDecodeError"}
	}
	return string(b), nil
}

// pyJoin: os.path.join(a, b): b itself if it is absolute
func pyJoin(a, b string) string {
	if strings.HasPrefix(b, "/") {
		return b
	}
	if a == "" || strings.HasSuffix(a, "/") {
		return a + b
	}
	return a + "/" + b
}

var (
	b58 = func(r rune) bool { return r < 0x80 && isRun(r) }
	// TEXT: escaped text, no markup, no bidi controls, at most 1000 characters (an entity one),
	// and none where 90 base58 or non-ASCII characters follow (the rule in rep)
	textChar = func(r rune) bool {
		return !strings.ContainsRune("<>\"'&", r) && r > 0x1f && r != 0x7f && !(r >= 0x202a && r <= 0x202e) && !(r >= 0x2066 && r <= 0x2069)
	}
	TEXT  = rep(orEntity(textChar), 0, 1000, false)
	LOOSE = rep(class(func(r rune) bool { return r != '<' && r != '>' && r != '\n' }), 0, 4000, false)
	NAME  = rep(orEntity(func(r rune) bool { return !strings.ContainsRune("\"<>/&\n", r) }), 1, 300, false)
	digit = class(func(r rune) bool { return r >= '0' && r <= '9' })
	NUM   = rep(digit, 1, 30, false)
	XMR   = seq(rep(digit, 1, 30, false), opt(seq(lit("."), rep(digit, 1, 30, false))))
	DATE  = opt(seq(alt(lits("January", "February", "March", "April", "May", "June", "July", "August", "September",
		"October", "November", "December")...), lit(" "), class1('1', '9'), opt(digit1), lit(", "), rep(digit, 4, 4, false)))
	MR = seq(alt(lit("/-/merge_requests/"), lit("/merge_requests/"), lit("/pulls/")), rep(digit, 1, 10, false))
)

func init() { TEXT = rep(orEntity(textChar), 0, 1000, true) }

func lits(ts ...string) []node {
	ns := make([]node, len(ts))
	for i, t := range ts {
		ns[i] = lit(t)
	}
	return ns
}

func class1(lo, hi rune) node {
	return rep(class(func(r rune) bool { return r >= lo && r <= hi }), 1, 1, false)
}

var digit1 = rep(digit, 1, 1, false)

func part(t string) string  { return strings.TrimSuffix(t, "\n") } // as jq rtrimstr("\n")
func strip(t string) string { return strings.TrimRight(t, "\n") }  // $(cat FILE)
func prefixOf(depth int) string {
	if depth == 0 {
		return "./"
	}
	return strings.Repeat("../", depth)
}

var relRx = regexp.MustCompile("((?:href|src)=\")/([^/\n])")

// rel: as relative_links in ccs-front-bash, a line at a time as sed
func rel(t string, depth int) string {
	return relRx.ReplaceAllString(t, "${1}"+strings.ReplaceAll(prefixOf(depth), "$", "$$")+"${2}")
}

// esc: as jq @html (1.6 writes ' as &#39;, later ones as &apos;: same reads both)
func esc(s string) string {
	return strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;", "'", "&#39;", "\"", "&quot;").Replace(s)
}

func same(a, b string) bool {
	return strings.ReplaceAll(a, "&apos;", "&#39;") == strings.ReplaceAll(b, "&apos;", "&#39;")
}

var slotRx = regexp.MustCompile(`\{\{([a-z_]+)\}\}`)

// put: as common.jq fill: every {{slot}}, in one pass
func put(t string, v map[string]string) (string, error) {
	var err error
	out := slotRx.ReplaceAllStringFunc(t, func(m string) string {
		x, ok := v[m[2:len(m)-2]]
		if !ok && err == nil {
			err = keyError{m[2 : len(m)-2]}
		}
		return x
	})
	return out, err
}

// the signed list: its addresses (the only ones a donation box may show), its main address and
// fingerprint, as check_addresses shows them on Verify
type list struct {
	listed    map[string]bool
	main, fpr string
	net       string
}

func readList(lst string) (*list, error) {
	t, err := read(lst)
	if err != nil {
		return nil, err
	}
	l := &list{listed: map[string]bool{}}
	found := false
	for _, line := range strings.Split(t, "\n") {
		r := strings.Fields(line)
		if len(r) >= 2 {
			l.listed[r[1]] = true
		}
		if len(r) >= 2 && r[0] == "0" && !found {
			l.main, found = r[1], true
		}
	}
	if !found {
		return nil, errors.New("the list has no index 0")
	}
	pin, err := read(lst + ".pin")
	if err != nil {
		return nil, err
	}
	found = false
	for _, line := range strings.Split(pin, "\n") {
		if strings.HasPrefix(line, "key ") {
			l.fpr, found = strings.TrimSpace(line[4:]), true
			break
		}
	}
	if !found {
		return nil, errors.New("the .pin has no key")
	}
	l.fpr = regexp.MustCompile("(.{4})").ReplaceAllString(l.fpr, "$1 ")
	l.fpr = strings.TrimSuffix(l.fpr, " ")
	if m := regexp.MustCompile("^((.{4} ){5})").FindStringIndex(l.fpr); m != nil {
		l.fpr = l.fpr[:m[1]] + " " + l.fpr[m[1]:]
	}
	switch {
	case strings.ContainsRune("9A", rune(l.main[0])):
		l.net = " --testnet"
	case strings.ContainsRune("57", rune(l.main[0])):
		l.net = " --stagenet"
	}
	return l, nil
}

// a proposal as markdown.awk renders it, from one commit: its text, milestones and payouts
// (JSON, read when a page's text is the same)
type body struct{ text, milestones, payouts string }

// readBodies: each proposal's renderings, from each commit (any of them will do)
func readBodies(files string) (map[string][]body, error) {
	md := map[string][]body{}
	for _, f := range strings.Split(files, ":") {
		if f == "" {
			continue
		}
		if _, err := os.Stat(f); err != nil {
			continue
		}
		t, err := read(f)
		if err != nil {
			return nil, err
		}
		for _, line := range splitlines(t) {
			if line == "" {
				continue
			}
			var j struct {
				File       *string         `json:"file"`
				Body       *string         `json:"body"`
				Milestones json.RawMessage `json:"milestones"`
				Payouts    json.RawMessage `json:"payouts"`
			}
			if err := json.Unmarshal([]byte(line), &j); err != nil || j.File == nil || j.Body == nil {
				return nil, errors.New("a line of markdown.awk's that pages_py could not read")
			}
			b := body{strings.ReplaceAll(*j.Body, "\x01", ""), orEmpty(j.Milestones), orEmpty(j.Payouts)}
			// (a set in pages_py: the same rendering from two commits once)
			dup := false
			for _, o := range md[*j.File] {
				dup = dup || o == b
			}
			if !dup {
				md[*j.File] = append(md[*j.File], b)
			}
		}
	}
	return md, nil
}

func orEmpty(m json.RawMessage) string {
	if m == nil {
		return "[]"
	}
	return string(m)
}

// rows: markdown.awk's milestones or payouts, each a list of strings (another shape: the
// exception pages_py would have met)
func rows(m string, n int) ([][]string, error) {
	var xs []any
	if err := json.Unmarshal([]byte(m), &xs); err != nil {
		return nil, pyError{"TypeError"}
	}
	var out [][]string
	for _, x := range xs {
		l, ok := x.([]any)
		if !ok {
			return nil, pyError{"TypeError"}
		}
		if len(l) < n {
			return nil, pyError{"IndexError"}
		}
		var r []string
		for _, v := range l[:n] {
			s, ok := v.(string)
			if !ok {
				return nil, pyError{"AttributeError"}
			}
			r = append(r, s)
		}
		out = append(out, r)
	}
	return out, nil
}

// splitlines: str.splitlines (lines end at \n, \r, \r\n and the others Python knows)
func splitlines(t string) []string {
	var out []string
	start := 0
	rs := []rune(t)
	for i := 0; i < len(rs); i++ {
		switch rs[i] {
		case '\n', '\r', '\v', '\f', 0x1c, 0x1d, 0x1e, 0x85, 0x2028, 0x2029:
			out = append(out, string(rs[start:i]))
			if rs[i] == '\r' && i+1 < len(rs) && rs[i+1] == '\n' {
				i++
			}
			start = i + 1
		}
	}
	if start < len(rs) {
		out = append(out, string(rs[start:]))
	}
	return out
}

// Checker: pages_py's state: the designs, the list, the proposals' renderings, where a link to a
// proposal may go, the onion
type Checker struct {
	designs []*design
	l       *list
	md      map[string][]body
	link    node
	onion   string
	viewkey string
	cache   map[string]*compiled
	diag    int
	max     int64
}

// MaxPage: a larger page is not read (held back)
const MaxPage = 2 << 20

// New: as pages_py's first lines (site, designs, bodies, list, viewkey, hosts, onion)
func New(designs, bodies, lst, viewkey, hosts, onion string) (*Checker, error) {
	// (2 MB at most, CCS_GATE_MAX if less: the largest page is under 200 kB, and matching one
	// takes memory as it goes, about 130 MB a MB)
	c := &Checker{onion: onion, viewkey: viewkey, cache: map[string]*compiled{}, diag: 10, max: MaxPage}
	if v, err := strconv.ParseInt(os.Getenv("CCS_GATE_MAX"), 10, 64); err == nil {
		c.max = min(v, MaxPage)
	}
	var err error
	if c.l, err = readList(lst); err != nil {
		return nil, err
	}
	if c.md, err = readBodies(bodies); err != nil {
		return nil, err
	}
	hs := strings.Fields(hosts)
	if len(hs) == 0 {
		c.link = never
	} else {
		var alts []node
		for _, h := range hs {
			alts = append(alts, lit(strings.Trim(h, "/")))
		}
		c.link = seq(lit("https://"), alt(alts...), MR)
	}
	for _, d := range strings.Split(designs, ":") {
		if d == "" {
			continue
		}
		ds, err := newDesign(c, d)
		if err != nil {
			return nil, err
		}
		c.designs = append(c.designs, ds)
	}
	return c, nil
}

type design struct {
	c *Checker
	d string
	p map[string]string
}

func newDesign(c *Checker, d string) (*design, error) {
	es, err := os.ReadDir(filepath.Join(d, "parts"))
	if err != nil {
		return nil, err
	}
	ds := &design{c: c, d: d, p: map[string]string{}}
	for _, e := range es {
		if strings.HasSuffix(e.Name(), ".html") {
			t, err := read(filepath.Join(d, "parts", e.Name()))
			if err != nil {
				return nil, err
			}
			ds.p[strings.TrimSuffix(e.Name(), ".html")] = t
		}
	}
	return ds, nil
}

func (d *design) part(name string) (string, error) {
	t, ok := d.p[name]
	if !ok {
		return "", keyError{name}
	}
	return t, nil
}

// pats: each slot's pattern, by its name
type pats map[string]node

// fill: the pattern of a part: its literal text as it is, each {{slot}} by slots; a slot in
// sameNames is one value however often the part has it (a group, then a backreference)
func (d *design) fill(text string, slots pats, sameNames ...string) (node, []string, error) {
	var ns []node
	var groups []string
	seen := map[string]bool{}
	i := 0
	for _, m := range slotRx.FindAllStringSubmatchIndex(text, -1) {
		k := text[m[2]:m[3]]
		s, ok := slots[k]
		if !ok {
			return nil, nil, keyError{k}
		}
		ns = append(ns, lit(text[i:m[0]]))
		isSame := false
		for _, n := range sameNames {
			isSame = isSame || n == k
		}
		switch {
		case isSame && seen[k]:
			ns = append(ns, backref(k))
		case isSame:
			ns = append(ns, group(k, s))
			groups = append(groups, k)
			seen[k] = true
		default:
			ns = append(ns, s)
		}
		i = m[1]
	}
	ns = append(ns, lit(text[i:]))
	return seq(ns...), groups, nil
}

// the pattern of a page, and the named groups it has (a name twice: re's error)
type built struct {
	n      node
	groups []string
}

func (b *built) add(n node, gs []string) node { b.groups = append(b.groups, gs...); return n }

func (d *design) segs() (node, error) {
	done, err := d.part("segment-done")
	if err != nil {
		return nil, err
	}
	todo, err := d.part("segment-todo")
	if err != nil {
		return nil, err
	}
	return star(alt(lit(part(done)), lit(part(todo)))), nil
}

func (d *design) label(name string, extra pats) (node, error) {
	t, err := d.part(name)
	if err != nil {
		return nil, err
	}
	s := pats{"tag": TEXT, "color": seq(lit("tag-"), class1('0', '7'))}
	for k, v := range extra {
		s[k] = v
	}
	n, _, err := d.fill(part(t), s)
	return n, err
}

func href(depth int) node {
	return seq(lit(prefixOf(depth)+"explore/tag/"),
		rep(class(func(r rune) bool { return r < 0x80 && (isAlnum(r) || strings.ContainsRune("%._~-", r)) }), 1, -1, false), lit("/"))
}

func isAlnum(r rune) bool {
	return r >= '0' && r <= '9' || r >= 'A' && r <= 'Z' || r >= 'a' && r <= 'z'
}

func funding() node { return opt(seq(lit(" \u00b7 funding since "), DATE)) }
func pending() node {
	return opt(seq(lit(" "), opt(lit("\u00b7 ")), opt(lit("+")), XMR, lit(" XMR pending")))
}

func (d *design) card(stage string, depth int, tagpage bool) (node, error) {
	t, err := d.part("card-" + stage)
	if err != nil {
		return nil, err
	}
	c := part(t)
	if tagpage {
		c = strings.ReplaceAll(c, "=\"../", "=\"../../../")
	}
	c = rel(c, depth)
	url := alt(lit("#"), seq(lit(prefixOf(depth)+"proposals/"), NAME, lit(".html")), d.c.link)
	seg, err := d.segs()
	if err != nil {
		return nil, err
	}
	label, err := d.label("label", nil)
	if err != nil {
		return nil, err
	}
	n, _, err := d.fill(c, pats{"url": url, "name": TEXT, "author": TEXT, "date": DATE,
		"funding_note": funding(), "funding_date": DATE, "contributors": NUM, "amount": XMR, "raised": XMR,
		"percentage": NUM, "done": NUM, "milestones": NUM, "pending_note": pending(),
		"upvotes": alt(NUM, lit("\u2013")), "downvotes": alt(NUM, lit("\u2013")), "segments": seg, "tags": star(label)})
	return n, err
}

func (d *design) nav(depth int) (node, error) {
	f, err := d.label("filter", pats{"href": href(depth), "count": NUM, "active": opt(lit(" active"))})
	if err != nil {
		return nil, err
	}
	t, err := d.part("filters")
	if err != nil {
		return nil, err
	}
	n, _, err := d.fill(part(t), pats{"filters": star(f)})
	if err != nil {
		return nil, err
	}
	return opt(n), nil
}

func (d *design) verify() (node, error) {
	t, err := d.part("verify")
	if err != nil {
		return nil, err
	}
	l := d.c.l
	slots := pats{"address": lit(l.main), "fingerprint": lit(l.fpr), "network": lit(l.net), "viewkey": never, "wallet_source": never}
	if d.c.viewkey != "" {
		vt, err := read(d.c.viewkey)
		if err != nil {
			return nil, err
		}
		v := splitlines(vt)
		if len(v) == 0 {
			return nil, pyError{"IndexError"}
		}
		src, txt := "", ""
		for _, line := range v {
			if strings.HasPrefix(line, "source ") {
				if src, err = secondField(line); err != nil {
					return nil, err
				}
				break
			}
		}
		for _, line := range v {
			if strings.HasPrefix(line, "source-text ") {
				if txt, err = secondField(line); err != nil {
					return nil, err
				}
				break
			}
		}
		txt = strings.ReplaceAll(txt, "'", "&#39;")
		slots["viewkey"] = lit(strings.ReplaceAll(v[0], " ", ""))
		if src != "" {
			if txt == "" {
				txt = "where they were published"
			}
			slots["wallet_source"] = lit("<a href=\"" + strings.ReplaceAll(src, "&", "&amp;") + "\">" + txt + "</a>")
		} else {
			slots["wallet_source"] = lit("published by this site")
		}
	}
	n, _, err := d.fill(strip(t), slots)
	return n, err
}

// secondField: l.split(None, 1)[1].strip(); an IndexError for a line of one word
func secondField(l string) (string, error) {
	f := strings.Fields(l)
	if len(f) < 2 {
		return "", pyError{"IndexError"}
	}
	i := strings.Index(l, f[0]) + len(f[0])
	return strings.TrimSpace(l[i:]), nil
}

// milestones: a proposal's milestones (markdown.awk's) as pages.jq makes them
func (d *design) milestones(b body, depth int) (string, error) {
	xs, err := rows(b.milestones, 3)
	if err != nil {
		return "", err
	}
	var lines []string
	for _, x := range xs {
		name := "milestone-todo"
		if x[2] != "" {
			name = "milestone-done"
		}
		t, err := d.part(name)
		if err != nil {
			return "", err
		}
		r, err := put(part(t), map[string]string{"name": esc(x[0]), "funds": esc(x[1]), "date": esc(x[2])})
		if err != nil {
			return "", err
		}
		lines = append(lines, r)
	}
	return d.orNone(lines, "no-milestones", depth)
}

func (d *design) payouts(b body, depth int) (string, error) {
	xs, err := rows(b.payouts, 2)
	if err != nil {
		return "", err
	}
	var lines []string
	for _, x := range xs {
		t, err := d.part("payout")
		if err != nil {
			return "", err
		}
		r, err := put(part(t), map[string]string{"date": esc(x[0]), "amount": esc(x[1])})
		if err != nil {
			return "", err
		}
		lines = append(lines, r)
	}
	return d.orNone(lines, "no-payouts", depth)
}

// orNone: the lines, or the design's part for none, links made relative
func (d *design) orNone(lines []string, none string, depth int) (string, error) {
	r := strings.Join(lines, "\n")
	if r == "" {
		t, err := d.part(none)
		if err != nil {
			return "", err
		}
		r = part(t)
	}
	return rel(r, depth), nil
}

func (d *design) slots(depth int, body bool) (pats, error) {
	seg, err := d.segs()
	if err != nil {
		return nil, err
	}
	vl, err := d.part("verify-link")
	if err != nil {
		return nil, err
	}
	ll, err := d.label("label-link", pats{"href": href(depth)})
	if err != nil {
		return nil, err
	}
	s := pats{"name": TEXT, "author": TEXT, "date": DATE, "funding_note": funding(), "funding_date": DATE,
		"contributors": NUM, "amount": XMR, "raised": XMR, "percentage": NUM, "done": NUM, "milestones": NUM,
		"pending_note": pending(), "gitlab_url": alt(lit("#"), d.c.link), "segments": seg,
		"needed_note": opt(seq(lit(" "), XMR, lit(" XMR would fund it 100%!"))),
		"address":     rep(class(b58), 95, 95, false),
		"qr": seq(lit("data:image/png;base64,"), rep(class(func(r rune) bool { return r < 0x80 && (isAlnum(r) || r == '+' || r == '/') }), 1, -1, false),
			rep(class(func(r rune) bool { return r == '=' }), 0, -1, false)),
		"verify_link": lit(strip(vl)), "milestones_list": empty, "payouts_list": empty, "tag_links": star(ll)}
	if body {
		s["body"] = group("body", lazy)
	}
	return s, nil
}

// region: what region NAME may hold on a page DEPTH folders down; on a proposal page (body) the
// milestones and payouts are kept (groups), to compare with the repository after
func (d *design) region(b *built, name string, depth int, tagpage, body bool) (node, error) {
	kind, arg, _ := strings.Cut(name, " ")
	switch kind {
	case "count", "number":
		return NUM, nil
	case "title":
		return TEXT, nil
	case "filters":
		return d.nav(depth)
	case "verify":
		return d.verify()
	case "onion":
		t, ok := d.p["onion"]
		if d.c.onion == "" || !ok {
			return empty, nil
		}
		r, err := put(part(t), map[string]string{"onion": d.c.onion})
		if err != nil {
			return nil, err
		}
		return opt(lit(r)), nil
	case "list":
		c, err := d.card(arg, depth, tagpage)
		if err != nil {
			return nil, err
		}
		e, err := d.part("empty")
		if err != nil {
			return nil, err
		}
		return opt(alt(seq(c, star(seq(lit("\n"), c))), lit(part(e)))), nil
	case "donate", "funded":
		t, err := d.part(kind)
		if err != nil {
			return nil, err
		}
		s, err := d.slots(depth, false)
		if err != nil {
			return nil, err
		}
		r, gs, err := d.fill(part(t), s, "address", "qr")
		if err != nil {
			return nil, err
		}
		r = b.add(r, gs)
		if f, ok := d.p["donate-funded"]; ok && kind == "donate" {
			s["percentage"] = lit("100")
			fr, _, err := d.fill(part(f), s)
			if err != nil {
				return nil, err
			}
			r = alt(r, fr)
		}
		return r, nil
	}
	t := TEXT
	if body {
		t = LOOSE
	}
	var r node
	switch kind {
	case "milestones":
		dt, err := d.part("milestone-done")
		if err != nil {
			return nil, err
		}
		dn, _, err := d.fill(part(dt), pats{"name": t, "funds": t, "date": t})
		if err != nil {
			return nil, err
		}
		tt, err := d.part("milestone-todo")
		if err != nil {
			return nil, err
		}
		tn, _, err := d.fill(part(tt), pats{"name": t, "funds": t})
		if err != nil {
			return nil, err
		}
		no, err := d.part("no-milestones")
		if err != nil {
			return nil, err
		}
		m := alt(dn, tn)
		r = alt(seq(m, star(seq(lit("\n"), m))), lit(part(no)))
	case "payouts":
		pt, err := d.part("payout")
		if err != nil {
			return nil, err
		}
		m, _, err := d.fill(part(pt), pats{"amount": t, "date": t})
		if err != nil {
			return nil, err
		}
		no, err := d.part("no-payouts")
		if err != nil {
			return nil, err
		}
		r = alt(seq(m, star(seq(lit("\n"), m))), lit(part(no)))
	default:
		return nil, keyError{name}
	}
	if body {
		return b.add(group(kind, r), []string{kind}), nil
	}
	return r, nil
}

var markerRx = regexp.MustCompile(`<!-- ccs:([a-z]+(?: [a-z]+)?) -->`)

// page: the pattern of a page in segments (for the reason: how far it is the design): its
// literal text, the regions as above, the slots (on a proposal page)
func (d *design) page(text string, depth int, tagpage, body bool) ([]node, []string, error) {
	b := &built{}
	var out []node
	lits := func(t string) (node, error) {
		if !body {
			return lit(rel(t, depth)), nil
		}
		s, err := d.slots(depth, true)
		if err != nil {
			return nil, err
		}
		n, _, err := d.fill(rel(t, depth), s)
		// (each {{body}} a group named body: twice on a page is re's error)
		for range strings.Count(rel(t, depth), "{{body}}") {
			b.add(nil, []string{"body"})
		}
		return n, err
	}
	i := 0
	for _, m := range markerRx.FindAllStringSubmatchIndex(text, -1) {
		name := text[m[2]:m[3]]
		end := "<!-- /ccs:" + name + " -->"
		j := strings.Index(text[m[1]:], end)
		if j < 0 {
			return nil, nil, pyError{"ValueError"}
		}
		j += m[1]
		seg := ""
		if i < m[0] {
			seg = text[i:m[0]]
		}
		n, err := lits(seg)
		if err != nil {
			return nil, nil, err
		}
		out = append(out, n)
		r, err := d.region(b, name, depth, tagpage, body)
		if err != nil {
			return nil, nil, err
		}
		nl := star(lit("\n"))
		out = append(out, seq(lit(text[m[0]:m[1]]), nl, r, nl, lit(end)))
		i = j + len(end)
	}
	rest := ""
	if i < len(text) {
		rest = text[i:]
	}
	n, err := lits(rest)
	if err != nil {
		return nil, nil, err
	}
	out = append(out, n)
	return out, b.groups, nil
}

type compiled struct {
	n    node
	segs []node
}

func (d *design) compiled(key, text string, depth int, tagpage, body bool) (*compiled, error) {
	k := fmt.Sprintf("%s\x00%s\x00%d\x00%v", d.d, key, depth, tagpage)
	if c, ok := d.c.cache[k]; ok {
		return c, nil
	}
	segs, groups, err := d.page(text, depth, tagpage, body)
	if err != nil {
		return nil, err
	}
	// a group name twice: re.compile's error ("redefinition of group name")
	sort.Strings(groups)
	for i := 1; i < len(groups); i++ {
		if groups[i] == groups[i-1] {
			return nil, pyError{"error"}
		}
	}
	c := &compiled{seq(segs...), segs}
	d.c.cache[k] = c
	return c, nil
}

var tagPage = regexp.MustCompile(`^explore/tag/[^/]+/index\.html\n?$`)

// box: a donation box's address and its QR code's base64
type box struct{ addr, qr string }

// check: ("", box or nil) if the page passes, else (reason, nil)
func (d *design) check(rp, got string) (string, *box, error) {
	depth := strings.Count(rp, "/")
	var want []body
	var tries []*compiled
	switch {
	case strings.HasPrefix(rp, "proposals/"):
		name := rp[len("proposals/"):]
		name = name[:max(0, len(name)-len(".html"))]
		if strings.Contains(name, "/") {
			return "a page the design does not have", nil, nil
		}
		w, ok := d.c.md[name]
		if !ok {
			return "a proposal page with no proposal (" + name + ".md) in the proposals repository", nil, nil
		}
		want = w
		for _, s := range []string{"fr", "wip", "cp"} {
			t, err := d.part("proposal-" + s)
			if err != nil {
				return "", nil, err
			}
			c, err := d.compiled("proposal-"+s, t+"\n", depth, false, true)
			if err != nil {
				return "", nil, err
			}
			tries = append(tries, c)
		}
	case tagPage.MatchString(rp):
		t, err := read(filepath.Join(d.d, "explore/tag/example/index.html"))
		if err != nil {
			return "", nil, err
		}
		c, err := d.compiled("tag", t, depth, true, false)
		if err != nil {
			return "", nil, err
		}
		tries = append(tries, c)
	case !strings.HasPrefix(rp, "parts/") && !strings.HasPrefix(rp, "explore/tag/") && isFile(pyJoin(d.d, rp)):
		t, err := read(pyJoin(d.d, rp))
		if err != nil {
			return "", nil, err
		}
		c, err := d.compiled(rp, t, depth, false, false)
		if err != nil {
			return "", nil, err
		}
		tries = append(tries, c)
	default:
		return "a page the design does not have", nil, nil
	}
	s := []rune(got)
	best, why := 0, "not a page of the design as ccs-front-bash fills it"
	for _, t := range tries {
		cx := newCtx(s)
		m := fullmatch(cx, t.n)
		if m && want != nil {
			bg := cx.g["body"]
			gbody := string(s[bg[0]:bg[1]])
			gm, hasM := cx.g["milestones"]
			gp, hasP := cx.g["payouts"]
			okAny := false
			for _, b := range want {
				if gbody != rel(b.text, depth) {
					continue
				}
				if hasM {
					ms, err := d.milestones(b, depth)
					if err != nil {
						return "", nil, err
					}
					if !same(string(s[gm[0]:gm[1]]), ms) {
						continue
					}
				}
				if hasP {
					ps, err := d.payouts(b, depth)
					if err != nil {
						return "", nil, err
					}
					if !same(string(s[gp[0]:gp[1]]), ps) {
						continue
					}
				}
				okAny = true
				break
			}
			if !okAny {
				// the page of the design, but another text than the proposal has in the repository
				best, why = bg[0], "not the text, milestones or payouts of its proposal as the proposals repository has them"
				continue
			}
		}
		if m {
			a, ok := cx.g["address"]
			if !ok {
				return "", nil, nil
			}
			addr := string(s[a[0]:a[1]])
			if !d.c.l.listed[addr] {
				return "a donation box with an address that is not in the signed list (" + addr + ")", nil, nil
			}
			q := cx.g["qr"]
			qr := string(s[q[0]:q[1]])
			return "", &box{addr, qr[strings.Index(qr, ",")+1:]}, nil
		}
		if d.c.diag <= 0 {
			continue
		}
		// how far it is the design, for the reason (10 pages)
		for k := len(t.segs); k > 0; k-- {
			if e := prefix(newCtx(s), seq(t.segs[:k]...)); e >= 0 {
				best = max(best, e)
				break
			}
		}
	}
	d.c.diag--
	if d.c.diag >= 0 {
		why += fmt.Sprintf(" (it differs at character %d: %s)", best, pyJSON(s[best:min(len(s), best+60)]))
	}
	return why, nil, nil
}

func isFile(p string) bool {
	st, err := os.Stat(p)
	return err == nil && st.Mode().IsRegular()
}

// pyJSON: json.dumps of a string (ensure_ascii: every character not printable ASCII escaped,
// those past U+FFFF as their two surrogates)
func pyJSON(rs []rune) string {
	var b strings.Builder
	b.WriteByte('"')
	for _, r := range rs {
		switch {
		case r == '"':
			b.WriteString(`\"`)
		case r == '\\':
			b.WriteString(`\\`)
		case r == '\n':
			b.WriteString(`\n`)
		case r == '\r':
			b.WriteString(`\r`)
		case r == '\t':
			b.WriteString(`\t`)
		case r == '\b':
			b.WriteString(`\b`)
		case r == '\f':
			b.WriteString(`\f`)
		case r >= 0x20 && r <= 0x7e:
			b.WriteRune(r)
		case r > 0xffff:
			r -= 0x10000
			fmt.Fprintf(&b, `\u%04x\u%04x`, 0xd800+(r>>10), 0xdc00+(r&0x3ff))
		default:
			fmt.Fprintf(&b, `\u%04x`, r)
		}
	}
	b.WriteByte('"')
	return b.String()
}

// Run: pages_py: SITE, then the pages (NUL-separated, relative to SITE) from in; a line per
// page as pages_py's, each written as soon as it is known
func (c *Checker) Run(site string, in io.Reader, w *bufio.Writer) error {
	all, err := io.ReadAll(in)
	if err != nil {
		return err
	}
	for _, rp := range strings.Split(string(all), "\x00") {
		if rp == "" {
			continue
		}
		p := pyJoin(site, rp)
		st, err := os.Stat(p)
		if err == nil && st.Size() > c.max {
			fmt.Fprintf(w, "%s\t!a page over %d MB\n", p, c.max>>20)
			w.Flush()
			continue
		}
		got, err := read(p)
		if err != nil {
			fmt.Fprintf(w, "%s\t!a page that is not UTF-8\n", p)
			w.Flush()
			continue
		}
		why, bx := "", (*box)(nil)
		for _, d := range c.designs {
			var err error
			why, bx, err = d.check(rp, got)
			var ke keyError
			var pe pyError
			switch {
			case errors.As(err, &ke):
				why = "the design has no part or slot " + ke.Error()
			case errors.As(err, &pe):
				why = "a page that could not be checked (" + pe.name + ")"
			case err != nil:
				why = "a page that could not be checked (Exception)"
			}
			if why == "" {
				break
			}
		}
		if why != "" {
			fmt.Fprintf(w, "%s\t!%s\n", p, why)
		} else {
			if bx != nil {
				fmt.Fprintf(w, "%s\t=box\t%s\t%s\n", p, bx.addr, bx.qr)
			}
			fmt.Fprintf(w, "%s\t=ok\n", p)
		}
		w.Flush()
	}
	return nil
}

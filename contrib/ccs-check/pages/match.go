package pages

// The patterns pages_py built as Python regexes, as a tree of nodes matched by backtracking in
// Python's re's order (the first alternative first, a greedy repeat its longest first, a lazy
// one its shortest), so the same match, the same groups, and the same "differs at character N".
// Only what pages_py's patterns use: literals, runs of one kind of unit counted (a character of a
// class, or an entity), alternatives, a greedy *, a lazy .*?, named groups, a backreference, and
// TEXT's lookahead (no run of 90 base58 or non-ASCII characters from any of its positions) as a
// rule of the run itself. Go's regexp (RE2) has no lookahead or backreference, and expands a
// count ({0,1000}) into as many copies.

// node: match at s[i:], then k at each end in order until it returns true
type node func(c *ctx, i int, k func(int) bool) bool

type ctx struct {
	s   []rune
	run []int             // run[i]: how many base58 or non-ASCII characters from i on
	g   map[string][2]int // the named groups matched, start and end
}

func newCtx(s []rune) *ctx {
	c := &ctx{s: s, run: make([]int, len(s)+1), g: map[string][2]int{}}
	for i := len(s) - 1; i >= 0; i-- {
		if isRun(s[i]) {
			c.run[i] = c.run[i+1] + 1
		}
	}
	return c
}

// a character of an address, or one that could stand for one (any not ASCII)
func isRun(r rune) bool {
	return r > 0x7f || r >= '1' && r <= '9' || r >= 'A' && r <= 'Z' && r != 'I' && r != 'O' || r >= 'a' && r <= 'z' && r != 'l'
}

func lit(t string) node {
	r := []rune(t)
	return func(c *ctx, i int, k func(int) bool) bool {
		if i+len(r) > len(c.s) {
			return false
		}
		for j, x := range r {
			if c.s[i+j] != x {
				return false
			}
		}
		return k(i + len(r))
	}
}

func seq(ns ...node) node {
	var at func(c *ctx, j, i int, k func(int) bool) bool
	at = func(c *ctx, j, i int, k func(int) bool) bool {
		if j == len(ns) {
			return k(i)
		}
		return ns[j](c, i, func(e int) bool { return at(c, j+1, e, k) })
	}
	return func(c *ctx, i int, k func(int) bool) bool { return at(c, 0, i, k) }
}

func alt(ns ...node) node {
	return func(c *ctx, i int, k func(int) bool) bool {
		for _, n := range ns {
			if n(c, i, k) {
				return true
			}
		}
		return false
	}
}

func empty(c *ctx, i int, k func(int) bool) bool { return k(i) }

func never(c *ctx, i int, k func(int) bool) bool { return false }

func opt(n node) node { return alt(n, empty) }

// star: (?:n)*, greedy; an iteration that matched nothing ends it (as re)
func star(n node) node {
	var loop func(c *ctx, i int, k func(int) bool) bool
	loop = func(c *ctx, i int, k func(int) bool) bool {
		if n(c, i, func(e int) bool { return e != i && loop(c, e, k) }) {
			return true
		}
		return k(i)
	}
	return loop
}

// unit: the length of one unit at s[i:] (a character of a class, or an entity), 0 for none
type unit func(s []rune, i int) int

// rep: min to max units (max < 0: no limit), greedy; with guard, none starting where 90
// base58 or non-ASCII characters follow (TEXT's (?!RUN{90}))
func rep(u unit, min, max int, guard bool) node {
	return func(c *ctx, i int, k func(int) bool) bool {
		ends := []int{i}
		for p := i; max < 0 || len(ends)-1 < max; {
			if guard && c.run[p] >= 90 {
				break
			}
			l := u(c.s, p)
			if l == 0 {
				break
			}
			p += l
			ends = append(ends, p)
		}
		for n := len(ends) - 1; n >= min; n-- {
			if k(ends[n]) {
				return true
			}
		}
		return false
	}
}

// lazy: .*? (re.S: any character), the shortest first
func lazy(c *ctx, i int, k func(int) bool) bool {
	for e := i; e <= len(c.s); e++ {
		if k(e) {
			return true
		}
	}
	return false
}

// group: (?P<name>n); its value is the last one matched on the way to the end
func group(name string, n node) node {
	return func(c *ctx, i int, k func(int) bool) bool {
		return n(c, i, func(e int) bool {
			old, had := c.g[name]
			c.g[name] = [2]int{i, e}
			if k(e) {
				return true
			}
			if had {
				c.g[name] = old
			} else {
				delete(c.g, name)
			}
			return false
		})
	}
}

// backref: (?P=name), the text the group matched; nothing if it matched none
func backref(name string) node {
	return func(c *ctx, i int, k func(int) bool) bool {
		g, ok := c.g[name]
		if !ok {
			return false
		}
		n := g[1] - g[0]
		if i+n > len(c.s) {
			return false
		}
		for j := 0; j < n; j++ {
			if c.s[i+j] != c.s[g[0]+j] {
				return false
			}
		}
		return k(i + n)
	}
}

// fullmatch: n matches all of s (the groups in c after)
func fullmatch(c *ctx, n node) bool {
	return n(c, 0, func(e int) bool { return e == len(c.s) })
}

// prefix: where the first match of n at the start of s ends (as re.match), -1 for none
func prefix(c *ctx, n node) int {
	end := -1
	n(c, 0, func(e int) bool { end = e; return true })
	return end
}

// class: a unit of one character for which in is true
func class(in func(rune) bool) unit {
	return func(s []rune, i int) int {
		if i < len(s) && in(s[i]) {
			return 1
		}
		return 0
	}
}

// orEntity: a unit of one character of the class, or one of the entities ccs-bash and
// markdown.awk escape with (&amp; &lt; &gt; &quot; &#39; &apos;)
func orEntity(in func(rune) bool) unit {
	ents := [][]rune{[]rune("&amp;"), []rune("&lt;"), []rune("&gt;"), []rune("&quot;"), []rune("&#39;"), []rune("&apos;")}
	return func(s []rune, i int) int {
		if i >= len(s) {
			return 0
		}
		if in(s[i]) {
			return 1
		}
		for _, e := range ents {
			if i+len(e) <= len(s) && string(s[i:i+len(e)]) == string(e) {
				return len(e)
			}
		}
		return 0
	}
}

package pages

import (
	"fmt"
	"regexp"
	"strings"
	"testing"
)

// match.go against Go's regexp (review 9), on patterns of its nodes that RE2 has too (no
// backreference, no TEXT guard): the same answer, and the same span for a group (RE2's
// submatches are leftmost-first, Perl's and re's, so a backtracking matcher's).
type gen struct {
	b      []byte
	groups int
	stars  int
}

func (g *gen) next() byte {
	if len(g.b) == 0 {
		return 0
	}
	c := g.b[0]
	g.b = g.b[1:]
	return c
}

// pattern: a node and its regexp, at most depth deep, over the letters a, b and c
func (g *gen) pattern(depth int) (node, string) {
	k := g.next()
	if depth == 0 {
		k %= 3
	}
	switch k % 9 {
	case 0, 1:
		t := strings.Repeat(string(rune('a'+g.next()%3)), int(g.next()%3))
		return lit(t), regexp.QuoteMeta(t)
	case 2:
		lo := int(g.next() % 3)
		hi := lo + int(g.next()%3)
		c := rune('a' + g.next()%3)
		return rep(class(func(r rune) bool { return r == c }), lo, hi, false), fmt.Sprintf("%c{%d,%d}", c, lo, hi)
	case 3:
		a, ra := g.pattern(depth - 1)
		b, rb := g.pattern(depth - 1)
		return seq(a, b), ra + rb
	case 4:
		a, ra := g.pattern(depth - 1)
		b, rb := g.pattern(depth - 1)
		return alt(a, b), "(?:" + ra + "|" + rb + ")"
	case 5:
		// (a body that can't match nothing, as every star of pages.go's: one that can is ordered
		// otherwise than re's, the groups after it too)
		g.stars++
		a, ra := g.pattern(depth - 1)
		g.stars--
		l := string(rune('a' + g.next()%3))
		return star(seq(a, lit(l))), "(?:" + ra + l + ")*"
	case 6:
		a, ra := g.pattern(depth - 1)
		return opt(a), "(?:" + ra + ")?"
	case 7:
		return lazy, "(?s:.*?)"
	default:
		g.groups++
		name := fmt.Sprintf("g%d", g.groups)
		a, ra := g.pattern(depth - 1)
		return group(name, a), "(?P<" + name + ">" + ra + ")"
	}
}

func FuzzMatchVsRegexp(f *testing.F) {
	f.Add([]byte{3, 8, 2, 0, 1, 2, 5, 4, 0, 1, 1, 0, 0, 2}, "aab")
	f.Add([]byte{8, 3, 7, 8, 0, 2, 2}, "abcabc")
	f.Fuzz(func(t *testing.T, p []byte, s string) {
		if len(s) > 12 || strings.Trim(s, "abc") != "" {
			return
		}
		g := &gen{b: p}
		n, re := g.pattern(4)
		rx := regexp.MustCompile("^(?:" + re + ")$")
		c := newCtx([]rune(s))
		got := fullmatch(c, n)
		m := rx.FindStringSubmatchIndex(s)
		if got != (m != nil) {
			t.Fatalf("%q on %q: match.go %v, regexp %v", re, s, got, m != nil)
		}
		if !got {
			return
		}
		for i, name := range rx.SubexpNames() {
			if name == "" {
				continue
			}
			sp, ok := c.g[name]
			if (m[2*i] >= 0) != ok || ok && (sp[0] != m[2*i] || sp[1] != m[2*i+1]) {
				t.Fatalf("%q on %q: group %s: match.go %v %v, regexp %v", re, s, name, sp, ok, m[2*i:2*i+2])
			}
		}
	})
}

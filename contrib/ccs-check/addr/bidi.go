package addr

import (
	"slices"
	"unicode"
)

// Bidi reports a bidi control: the embeddings, overrides and isolates (U+202A-202E, U+2066-2069)
// and the marks (U+200E, U+200F, U+061C). Each can display text in a different order than it is
// written, so an address written in another order shows the right way round.
func Bidi(r rune) bool {
	return r >= 0x202a && r <= 0x202e || r >= 0x2066 && r <= 0x2069 || r == 0x200e || r == 0x200f || r == 0x061c
}

// rtl reports a character a browser reads as right to left: the letters of the right-to-left
// blocks (Hebrew, Arabic, Syriac, Thaana, NKo and others), unassigned ones there too, as Unicode
// says, and the right-to-left marks. Not their digits or combining marks.
func rtl(r rune) bool {
	if r == 0x200f || r == 0x061c {
		return true
	}
	in := r >= 0x0590 && r <= 0x08ff || r >= 0xfb1d && r <= 0xfdff || r >= 0xfe70 && r <= 0xfefe ||
		r >= 0x10800 && r <= 0x10fff || r >= 0x1e800 && r <= 0x1efff
	return in && !unicode.IsDigit(r) && !unicode.Is(unicode.Mn, r)
}

// ltr reports a character a browser reads as left to right: any other letter, and the
// left-to-right mark
func ltr(r rune) bool { return r == 0x200e || !rtl(r) && unicode.IsLetter(r) }

// RTL reports whether s has a right-to-left character (rtl)
func RTL(s string) bool {
	for _, r := range s {
		if rtl(r) {
			return true
		}
	}
	return false
}

// Visual returns s in the order a browser shows it, in a left-to-right page: Unicode's bidi
// algorithm, cut down to what moves digits. Between two left-to-right letters, from the first
// right-to-left character to the last one or the last digit after it, the text is shown
// reversed, except that each number keeps its own order. A number is a run of digits, joined by
// a single separator (. , : / + - or a no-break space) between two digits.
// So "tN<RLM>8 1<RLM>obc" shows as "tN 1 8obc" (the marks unseen): an address written that way
// reads correctly on screen.
func Visual(s string) string {
	rs := []rune(s)
	out := make([]rune, 0, len(rs))
	for i := 0; i < len(rs); {
		if ltr(rs[i]) {
			out = append(out, rs[i])
			i++
			continue
		}
		j := i
		for j < len(rs) && !ltr(rs[j]) {
			j++
		}
		out = append(out, reorder(rs[i:j])...)
		i = j
	}
	return string(out)
}

// reorder is Visual for a run with no left-to-right letter in it
func reorder(seg []rune) []rune {
	p := slices.IndexFunc(seg, rtl)
	if p < 0 {
		return seg
	}
	q := len(seg) - 1
	for q > p && !rtl(seg[q]) && !unicode.IsDigit(seg[q]) {
		q--
	}
	span := seg[p : q+1]
	// Split the span into numbers and single characters, then show them last to first
	var parts [][]rune
	for k := 0; k < len(span); {
		e := k + 1
		if unicode.IsDigit(span[k]) {
			for e < len(span) {
				if unicode.IsDigit(span[e]) {
					e++
				} else if e+1 < len(span) && separator(span[e]) && unicode.IsDigit(span[e+1]) {
					e += 2
				} else {
					break
				}
			}
		}
		parts = append(parts, span[k:e])
		k = e
	}
	out := append([]rune{}, seg[:p]...)
	for k := len(parts) - 1; k >= 0; k-- {
		out = append(out, parts[k]...)
	}
	return append(out, seg[q+1:]...)
}

func separator(r rune) bool {
	return r == '.' || r == ',' || r == ':' || r == '/' || r == '+' || r == '-' || r == 0xa0
}

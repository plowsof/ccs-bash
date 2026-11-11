package addr

import (
	"strings"
	"unicode"
)

// Bidi reports a bidi control: the embeddings, overrides and isolates (U+202A-202E, U+2066-2069)
// and the marks (U+200E, U+200F, U+061C). Each can display text in a different order than it is
// written, so an address written in another order shows the right way round.
func Bidi(r rune) bool {
	return r >= 0x202a && r <= 0x202e || r >= 0x2066 && r <= 0x2069 || r == 0x200e || r == 0x200f || r == 0x061c
}

// rtl reports a letter a browser reads as right to left: those of the right-to-left blocks
// (Hebrew, Arabic, Syriac, Thaana, NKo and others), unassigned ones there too, as Unicode says.
// Not their digits or combining marks.
func rtl(r rune) bool {
	in := r >= 0x0590 && r <= 0x08ff || r >= 0xfb1d && r <= 0xfdff || r >= 0xfe70 && r <= 0xfefe ||
		r >= 0x10800 && r <= 0x10fff || r >= 0x1e800 && r <= 0x1efff
	return in && !unicode.IsDigit(r) && !unicode.Is(unicode.Mn, r)
}

// Reordered reports text a browser shows with its numbers in another order than written: after
// a right-to-left letter, two numbers with no left-to-right letter between them (Unicode's bidi
// algorithm shows them last to first). "tN<Hebrew>8 1<Hebrew>obc" shows as "tN 1 8obc", so an
// address can be written so that it reads correctly only on screen. Text with that fails rather
// than being read in the browser's order. A number is digits joined by single separators
// (2026-11-11, 12.5). No proposal has right-to-left text with numbers today.
func Reordered(s string) bool {
	after, numbers, digit, sep := false, 0, false, false
	for _, r := range s {
		switch {
		case rtl(r):
			after = true
		case unicode.IsLetter(r):
			after, numbers = false, 0
		}
		if unicode.IsDigit(r) {
			if after && !digit && !sep {
				if numbers++; numbers == 2 {
					return true
				}
			}
			digit, sep = true, false
			continue
		}
		sep = digit && strings.ContainsRune(".,:/+- ", r)
		digit = false
	}
	return false
}

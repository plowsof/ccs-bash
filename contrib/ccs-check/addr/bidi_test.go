package addr

import (
	"strings"
	"testing"
)

func TestReordered(t *testing.T) {
	for in, want := range map[string]bool{
		"plain text, 1 2 3": false,
		"tNא8 1אobc":        true, // shows as "tN 1 8obc"
		"tN س 8 1 obc":      true,
		"שלום 2026-11-11":   false, // one number
		"שלום 12.5 x 34":    false, // a letter between the numbers
		"שלום 12.5, 34":     true,
		"12 א x 34":         false,
	} {
		if got := Reordered(in); got != want {
			t.Errorf("%q: %v", in, got)
		}
	}
}

func TestBidiMarks(t *testing.T) {
	for _, r := range []rune{0x200e, 0x200f, 0x061c, 0x202e, 0x2067} {
		if !Bidi(r) {
			t.Errorf("U+%04X is a bidi control", r)
		}
	}
	if Bidi('a') || Bidi(0x05d0) {
		t.Errorf("a letter isn't a bidi control")
	}
}

// An address in groups with a letter of a script no table lists, Lisu, Cherokee or mathematical
// Greek: disguised. Text in other scripts, and the address as written, aren't.
func TestDisguised(t *testing.T) {
	g := func(a string) string {
		var p []string
		for len(a) > 4 {
			p, a = append(p, a[:4]), a[4:]
		}
		return strings.Join(append(p, a), " ")
	}(fund)
	for in, want := range map[string]bool{
		strings.Replace(g, "A", "ꓮ", 1):          true,
		strings.Replace(g, "A", "Ꭺ", 2):          true,
		strings.Replace(g, "A", "\U0001d6a8", 1): true,
		g:                                        false,
		"Привет, мир: это предложение о переводе сайта Monero на русский язык, примерно 40 часов работы.": false,
		"Café meetup for the community in Paris; we need 25 XMR to rent a venue and print 300 stickers.":  false,
	} {
		if got := Disguised(in); got != want {
			t.Errorf("%q: %v", in, got)
		}
	}
}

package addr

import "testing"

func TestVisual(t *testing.T) {
	for in, want := range map[string]string{
		"plain text, 1 2 3": "plain text, 1 2 3",
		"tNא8 1אobc":        "tNא1 8אobc",
		"tN‏8 1‏obc":        "tN‏1 8‏obc",
		// A number keeps its own order, with one separator between digits
		"a א12.5 34ב b": "a ב34 12.5א b",
		// Digits before the first right-to-left letter, or after the last digit, stay put
		"x 12 א 34 y": "x 12 34 א y",
		"x א , y":     "x א , y",
	} {
		if got := Visual(in); got != want {
			t.Errorf("%q: %q, not %q", in, got, want)
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

// Unicode's confusables: scripts the hand-made table hasn't
func TestConfusables(t *testing.T) {
	for r, want := range map[rune]byte{0xa4ee: 'A', 0x13aa: 'A', 0x13f4: 'B', 0xa4e2: 'S', 0x1d6a8: 'A', 0x0410: 'A'} {
		if got := Lookalike(r); got != want {
			t.Errorf("U+%04X: %q, not %q", r, got, want)
		}
	}
}

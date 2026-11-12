package addr

import "testing"

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

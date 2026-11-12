package addr

// Bidi reports a bidi control: the embeddings, overrides and isolates (U+202A-202E, U+2066-2069)
// and the marks (U+200E, U+200F, U+061C). Each can display text in a different order than it is
// written, so an address written in another order shows the right way round.
func Bidi(r rune) bool {
	return r >= 0x202a && r <= 0x202e || r >= 0x2066 && r <= 0x2069 || r == 0x200e || r == 0x200f || r == 0x061c
}

package scan

import (
	"unicode/utf8"

	"ccs-check/addr"
)

// Nobidi: b without its bidi controls (addr.Bidi), as themselves (UTF-8) or as entities
// (&#x202E;, &#8238;): a proposal's text with one shows what follows it in another order than it
// is written (review 12's M-1), and one pasted with a number ("&#x202D;505.96 XMR", 36c3.md) is
// nothing a reader sees. Every other byte as it was, invalid UTF-8 too.
func Nobidi(b []byte) []byte {
	b = entities.ReplaceAllFunc(b, func(e []byte) []byte {
		if addr.Bidi(rune(code(string(e)))) {
			return nil
		}
		return e
	})
	out := make([]byte, 0, len(b))
	for i := 0; i < len(b); {
		r, w := utf8.DecodeRune(b[i:])
		if !(r != utf8.RuneError && addr.Bidi(r)) {
			out = append(out, b[i:i+w]...)
		}
		i += w
	}
	return out
}

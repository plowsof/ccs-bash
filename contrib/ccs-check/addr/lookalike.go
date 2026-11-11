package addr

import (
	"strings"
	"unicode"
)

// Non-ASCII letters and digits that look like ASCII ones (Unicode's confusables, TR39, for Latin
// letters and digits): Cyrillic, Greek, Armenian, Latin extensions, letterlike symbols.
// A reader copying an address by eye would type the ASCII one.
var lookalikes = map[rune]byte{
	// Cyrillic
	'А': 'A', 'В': 'B', 'Е': 'E', 'К': 'K', 'М': 'M', 'Н': 'H', 'О': 'O', 'Р': 'P', 'С': 'C', 'Т': 'T',
	'У': 'Y', 'Х': 'X', 'Ѕ': 'S', 'І': 'I', 'Ј': 'J', 'Ԛ': 'Q', 'Ԝ': 'W', 'Ү': 'Y', 'Ӏ': 'l', 'Ꙇ': 'l',
	'а': 'a', 'в': 'B', 'е': 'e', 'к': 'k', 'м': 'M', 'н': 'H', 'о': 'o', 'р': 'p', 'с': 'c', 'т': 'T',
	'у': 'y', 'х': 'x', 'ѕ': 's', 'і': 'i', 'ј': 'j', 'ԁ': 'd', 'ԛ': 'q', 'ԝ': 'w', 'һ': 'h', 'ӏ': 'l',
	'ү': 'y', 'ɡ': 'g', 'ԍ': 'G', 'Ь': 'b', 'ь': 'b', 'З': '3', 'з': '3', 'б': '6',
	// Greek
	'Α': 'A', 'Β': 'B', 'Ε': 'E', 'Ζ': 'Z', 'Η': 'H', 'Ι': 'I', 'Κ': 'K', 'Μ': 'M', 'Ν': 'N', 'Ο': 'O',
	'Ρ': 'P', 'Τ': 'T', 'Υ': 'Y', 'Χ': 'X', 'Ϲ': 'C', 'Ϳ': 'J', 'ο': 'o', 'ν': 'v', 'ι': 'i', 'α': 'a',
	'κ': 'k', 'ρ': 'p', 'υ': 'u', 'χ': 'x', 'ϲ': 'c', 'ϳ': 'j', 'γ': 'y', 'ϱ': 'p', 'ϸ': 'p',
	// Armenian
	'օ': 'o', 'ս': 'u', 'հ': 'h', 'ո': 'n', 'զ': 'q', 'ց': 'g', 'ա': 'w', 'Ս': 'U', 'Օ': 'O', 'Տ': 'S',
	// Latin extensions, and the letterlike symbols
	'ı': 'i', 'ȷ': 'j', 'ɑ': 'a', 'ɩ': 'i', 'ɪ': 'i', 'ʏ': 'y', 'ᴀ': 'A', 'ᴄ': 'c', 'ᴏ': 'o', 'ᴠ': 'v',
	'ᴡ': 'w', 'ᴢ': 'z', 'ꜱ': 's', 'ƽ': '5', 'Ƽ': '5', 'Ʒ': '3', 'ȝ': '3',
	'ℂ': 'C', 'ℊ': 'g', 'ℋ': 'H', 'ℌ': 'H', 'ℍ': 'H', 'ℎ': 'h', 'ℐ': 'I', 'ℑ': 'I', 'ℒ': 'L', 'ℓ': 'l',
	'ℕ': 'N', 'ℙ': 'P', 'ℚ': 'Q', 'ℛ': 'R', 'ℜ': 'R', 'ℝ': 'R', 'ℤ': 'Z', 'ℨ': 'Z', '\u212a': 'K', 'ℬ': 'B',
	'ℭ': 'C', 'ℯ': 'e', 'ℰ': 'E', 'ℱ': 'F', 'ℳ': 'M', 'ℴ': 'o', 'ℹ': 'i', 'ⅼ': 'l', 'ⅽ': 'c', 'ⅾ': 'd',
	'ⅿ': 'm', 'Ⅰ': 'I', 'Ⅴ': 'V', 'Ⅹ': 'X', 'Ⅼ': 'L', 'Ⅽ': 'C', 'Ⅾ': 'D', 'Ⅿ': 'M', 'ⅰ': 'i', 'ⅴ': 'v',
	'ⅹ': 'x',
}

// Lookalike returns the ASCII letter or digit that r looks like, or 0.
// Uses the full-width letters and digits (U+FF10-FF5A), the mathematical ones (U+1D400-1D6A3,
// U+1D7CE-1D7FF), the table above, then Unicode's confusables (confusables.go: Lisu, Cherokee,
// mathematical Greek and more). Each of the first two sets runs A to Z, a to z (or 0 to 9) in order.
func Lookalike(r rune) byte {
	switch {
	case r >= 0xff10 && r <= 0xff19, r >= 0xff21 && r <= 0xff3a, r >= 0xff41 && r <= 0xff5a:
		return byte(r - 0xfee0)
	case r >= 0x1d400 && r <= 0x1d6a3:
		if i := byte((r - 0x1d400) % 52); i < 26 {
			return 'A' + i
		} else {
			return 'a' + i - 26
		}
	case r >= 0x1d7ce && r <= 0x1d7ff:
		return '0' + byte((r-0x1d7ce)%10)
	}
	if l := lookalikes[r]; l != 0 {
		return l
	}
	return confusables[r]
}

// Lookalikes returns t as a reader copying it by eye would read it, and whether any character
// looked like ASCII. Each look-alike becomes its ASCII character (Lookalike). Invisible format
// characters (zero-width space, soft hyphen) are dropped. Any other non-ASCII becomes a space.
func Lookalikes(t string) (string, bool) {
	var b strings.Builder
	any := false
	for _, r := range t {
		switch {
		case r < 0x80:
			b.WriteRune(r)
		case Lookalike(r) != 0:
			b.WriteByte(Lookalike(r))
			any = true
		case unicode.Is(unicode.Cf, r):
		default:
			b.WriteByte(' ')
		}
	}
	return b.String(), any
}

// Readings returns the ways a reader could read text s: non-ASCII dropped, as a space, and as a
// reader copying by eye (Lookalikes). If s has a right-to-left letter, the same again for s in
// the order a browser shows it (Visual).
func Readings(s string) []string {
	var out []string
	from := []string{s}
	if RTL(s) {
		from = append(from, Visual(s))
	}
	for _, s := range from {
		for _, repl := range []rune{-1, ' '} {
			out = append(out, strings.Map(func(r rune) rune {
				if r > 0x7f {
					return repl
				}
				return r
			}, s))
		}
		if t, drawn := Lookalikes(s); drawn {
			out = append(out, t)
		}
	}
	return out
}

package addr

import (
	"strings"
	"unicode"
)

// the letters and digits not ASCII that are drawn as ASCII ones (Unicode's confusables, TR39, for
// Latin letters and digits: Cyrillic, Greek, Armenian, Latin's own extensions, the letterlike
// symbols): a reader copying an address by eye types the ASCII one
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
	// Latin's own, and the letterlike symbols
	'ı': 'i', 'ȷ': 'j', 'ɑ': 'a', 'ɩ': 'i', 'ɪ': 'i', 'ʏ': 'y', 'ᴀ': 'A', 'ᴄ': 'c', 'ᴏ': 'o', 'ᴠ': 'v',
	'ᴡ': 'w', 'ᴢ': 'z', 'ꜱ': 's', 'ƽ': '5', 'Ƽ': '5', 'Ʒ': '3', 'ȝ': '3',
	'ℂ': 'C', 'ℊ': 'g', 'ℋ': 'H', 'ℌ': 'H', 'ℍ': 'H', 'ℎ': 'h', 'ℐ': 'I', 'ℑ': 'I', 'ℒ': 'L', 'ℓ': 'l',
	'ℕ': 'N', 'ℙ': 'P', 'ℚ': 'Q', 'ℛ': 'R', 'ℜ': 'R', 'ℝ': 'R', 'ℤ': 'Z', 'ℨ': 'Z', '\u212a': 'K', 'ℬ': 'B',
	'ℭ': 'C', 'ℯ': 'e', 'ℰ': 'E', 'ℱ': 'F', 'ℳ': 'M', 'ℴ': 'o', 'ℹ': 'i', 'ⅼ': 'l', 'ⅽ': 'c', 'ⅾ': 'd',
	'ⅿ': 'm', 'Ⅰ': 'I', 'Ⅴ': 'V', 'Ⅹ': 'X', 'Ⅼ': 'L', 'Ⅽ': 'C', 'Ⅾ': 'D', 'Ⅿ': 'M', 'ⅰ': 'i', 'ⅴ': 'v',
	'ⅹ': 'x',
}

// Lookalike: the ASCII letter or digit r is drawn as, or 0: the table above, the full-width
// letters and digits (U+FF10-FF5A) and the mathematical ones (U+1D400-1D6A3, U+1D7CE-1D7FF), each
// set A to Z, a to z (or 0 to 9) in order
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
	return lookalikes[r]
}

// Lookalikes: t as a reader copying it by eye reads it: each character drawn as an ASCII one
// (Lookalike) that one, one that isn't drawn at all (a format character: a zero-width space, a
// soft hyphen) dropped, any other not ASCII a space; and whether any was drawn as ASCII
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

// Bidi: a bidi control (U+202A-202E, U+2066-2069), which can show the text after it in another
// order than it is written: an address reversed, in groups, shown the right way round
func Bidi(r rune) bool { return r >= 0x202a && r <= 0x202e || r >= 0x2066 && r <= 0x2069 }

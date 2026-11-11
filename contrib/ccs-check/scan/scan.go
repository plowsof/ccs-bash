// Package scan finds the addresses in the pages, the feed and the JSON. It prints one line per
// finding: "file<TAB>address" or "file<TAB>!reason", and for a page's data: images
// "file<TAB>?qr<TAB>base64". Those are held back: the site's QR codes are files, in qr/.
package scan

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"

	"ccs-check/addr"
)

// Max is the largest file read (CCS_GATE_MAX, 8 MB)
func Max() int64 {
	if v, err := strconv.ParseInt(os.Getenv("CCS_GATE_MAX"), 10, 64); err == nil {
		return v
	}
	return 8 << 20
}

// legacy lists the named entities a browser reads even without their ";" (from HTML's table:
// "&shy" is an invisible soft hyphen, whatever follows it). Longest first, as a browser matches them.
var legacy = func() string {
	ns := strings.Fields(`AElig AMP Aacute Acirc Agrave Aring Atilde Auml COPY Ccedil ETH Eacute Ecirc
		Egrave Euml GT Iacute Icirc Igrave Iuml LT Ntilde Oacute Ocirc Ograve Oslash Otilde Ouml QUOT
		REG THORN Uacute Ucirc Ugrave Uuml Yacute aacute acirc acute aelig agrave amp aring atilde auml
		brvbar ccedil cedil cent copy curren deg divide eacute ecirc egrave eth euml frac12 frac14
		frac34 gt iacute icirc iexcl igrave iquest iuml laquo lt macr micro middot nbsp not ntilde
		oacute ocirc ograve ordf ordm oslash otilde ouml para plusmn pound quot raquo reg sect shy sup1
		sup2 sup3 szlig thorn times uacute ucirc ugrave uml uuml yacute yen yuml`)
	sort.SliceStable(ns, func(i, j int) bool { return len(ns[i]) > len(ns[j]) })
	return strings.Join(ns, "|")
}()

var (
	starts   = regexp.MustCompile(`^[ \t\n\r]*[<\[{]`)
	controls = regexp.MustCompile(`[\x00-\x08\x0b\x0e-\x1f\x7f]`)
	entities = regexp.MustCompile(`&#[0-9]+;?|&#[xX][0-9A-Fa-f]+;?|&[A-Za-z][A-Za-z0-9]*;|&(?:` + legacy + `)`)
	// A data: image of any type. The scheme matches in any case, as in a browser.
	qrs  = regexp.MustCompile(`(?i)data:image/[A-Za-z0-9.+-]*[;,][A-Za-z0-9+/=;,.:%_-]*`)
	tags = regexp.MustCompile(`<[^>]*>`)
	// The named entities the scan reads: the escapes, and the punctuation the design and
	// proposals use. ccs-front-bash keeps only these in a proposal's text (it shows the rest as
	// written). A page with any other name fails (Unknown): a browser knows over 2000, among
	// them letters that look like an address's (&Alpha; is a Greek A).
	named = map[string]int{"amp": 38, "lt": 60, "gt": 62, "quot": 34, "apos": 39, "AMP": 38, "LT": 60, "GT": 62, "QUOT": 34,
		"nbsp": 0xa0, "ndash": 0x2013, "mdash": 0x2014, "hellip": 0x2026, "lsquo": 0x2018, "rsquo": 0x2019,
		"ldquo": 0x201c, "rdquo": 0x201d, "laquo": 0xab, "raquo": 0xbb, "middot": 0xb7, "bull": 0x2022,
		"copy": 0xa9, "reg": 0xae, "trade": 0x2122, "deg": 0xb0, "rarr": 0x2192, "larr": 0x2190, "euro": 0x20ac,
		"times": 0xd7}
)

// Unknown is the reason a page fails that has a named entity the scan doesn't read (named)
const Unknown = "!a named entity the scan doesn't read: it could be a letter that looks like an address's"

// char maps an entity's character: printable ASCII stays itself, a space stays a space, a
// look-alike becomes its ASCII letter or digit (addr.Lookalike: &#x430; is a Cyrillic a), and
// anything else becomes \x01 (read both ways).
// A < or > written as an entity is text a browser shows, never markup. It is read as punctuation,
// so an address's groups on either side of it still join.
func char(n int) string {
	if n == '<' || n == '>' {
		return "-"
	}
	if n > 32 && n < 127 {
		return string(rune(n))
	}
	if n == 9 || n == 10 || n == 12 || n == 13 || n == 32 {
		return " "
	}
	if l := addr.Lookalike(rune(n)); l != 0 {
		return string(rune(l))
	}
	return "\x01"
}

// number parses digits in base; -1 if too large to be a character (over 2^31)
func number(digits string, base int) int {
	digits = strings.TrimLeft(digits, "0")
	if digits == "" {
		return 0
	}
	if len(digits) > 8 {
		return -1
	}
	n, _ := strconv.ParseInt(digits, base, 64)
	return int(n)
}

// code returns an entity's character, or -1 (a name not in named, a number too large)
func code(e string) int {
	e = strings.TrimSuffix(e, ";")
	switch {
	case strings.HasPrefix(e, "&#x") || strings.HasPrefix(e, "&#X"):
		return number(e[3:], 16)
	case strings.HasPrefix(e, "&#"):
		return number(e[2:], 10)
	}
	if n, ok := named[e[1:]]; ok {
		return n
	}
	return -1
}

func entity(e string) string {
	if n := code(e); n >= 0 {
		return char(n)
	}
	return "\x01"
}

// Bidi is the reason a file with a bidi control fails, raw or as an entity. A browser displays the
// text after it in a different order than written, so an address written backwards in groups
// would read correctly on screen while the checks read it backwards.
const Bidi = "!a bidi control (U+202A-202E, U+2066-2069, U+200E, U+200F or U+061C): text shown in another order than it is written"

// unknown reports a named entity in d that code can't read
func unknown(d string) bool {
	for _, e := range entities.FindAllString(d, -1) {
		if e[1] != '#' && code(e) < 0 {
			return true
		}
	}
	return false
}

// shown returns the text of page raw in the order a browser shows it (addr.Visual), if it has a
// right-to-left letter, which puts the digits between two of them in another order. Tags are
// removed and entities decoded first. Look-alikes become their ASCII letter or digit, invisible
// format characters are dropped, and any other non-ASCII becomes \x01. "" if there's none.
func shown(raw []byte) string {
	t := tags.ReplaceAllString(string(raw), "")
	t = entities.ReplaceAllStringFunc(t, func(e string) string {
		switch n := code(e); {
		case n == '<' || n == '>':
			return "-"
		case n < 0 || n > unicode.MaxRune:
			return "\x01"
		default:
			return string(rune(n))
		}
	})
	if !addr.RTL(t) {
		return ""
	}
	return strings.Map(func(r rune) rune {
		switch {
		case r < 0x80:
			if r < 0x20 && r != '\t' && r != '\n' && r != '\r' && r != '\f' || r == 0x7f {
				return 1
			}
			return r
		case addr.Lookalike(r) != 0:
			return rune(addr.Lookalike(r))
		case unicode.Is(unicode.Cf, r):
			return -1
		}
		return 1
	}, addr.Visual(t))
}

// bidi reports a bidi control in raw (as UTF-8) or in d (raw as latin-1, entities still in it)
// as an entity
func bidi(raw []byte, d string) bool {
	if bytes.ContainsFunc(raw, addr.Bidi) {
		return true
	}
	for _, e := range entities.FindAllString(d, -1) {
		if addr.Bidi(rune(code(e))) {
			return true
		}
	}
	return false
}

// Pages scans a page, feed or JSON file as text, read as bytes.
// It must start like a page or JSON (<, [ or {), otherwise a browser might show it as an image.
// It must have no bidi control.
// Non-ASCII bytes and control characters are read twice: dropped, and as a space.
// Entities are decoded as a browser does (&#56; is 8).
// If a character looks like an ASCII letter or digit (a Cyrillic а, a full-width Ａ), the text is
// read a third time, as a reader copying it by eye would (addr.Lookalikes).
func Pages(files []string, w io.Writer) error {
	c, max := addr.New(), Max()
	for _, f := range files {
		st, err := os.Stat(f)
		if err != nil {
			return err
		}
		if st.Size() > max {
			fmt.Fprintf(w, "%s\t!over %d MB: not read\n", f, max>>20)
			continue
		}
		raw, err := os.ReadFile(f)
		if err != nil {
			return err
		}
		// Read bytes as latin-1, one character each; non-ASCII ones become \x01 first
		b := make([]byte, len(raw))
		for i, x := range raw {
			if x >= 0x80 {
				x = 1
			}
			b[i] = x
		}
		d := string(b)
		out := map[string]bool{}
		if !starts.MatchString(d) {
			out["!not text that starts as a page or JSON does (<, [ or {): a browser would show it as an image"] = true
		}
		if bidi(raw, d) {
			out[Bidi] = true
		}
		if unknown(d) {
			out[Unknown] = true
		}
		readings := []string{d}
		if t, drawn := addr.Lookalikes(string(raw)); drawn {
			readings = append(readings, t)
		}
		c.Start()
		for i, t := range readings {
			t = entities.ReplaceAllStringFunc(controls.ReplaceAllString(t, "\x01"), entity)
			if i == 0 {
				for _, m := range qrs.FindAllString(t, -1) {
					fmt.Fprintf(w, "%s\t?qr\t%s\n", f, m)
				}
			}
			t = qrs.ReplaceAllString(t, " ")
			if err := both(c, t, out); err != nil {
				out["!"+err.Error()] = true
				break
			}
		}
		if t := shown(raw); t != "" {
			if err := both(c, qrs.ReplaceAllString(t, " "), out); err != nil {
				out["!"+err.Error()] = true
			}
		}
		emit(w, f, out)
	}
	return nil
}

// both finds the addresses in t, read with each \x01 dropped and as a space. Then again in t as a
// browser lays it out, with tags removed, checksum only. (An address split across two elements
// side by side, such as two tag labels or a tag and its count, forms one run there.)
// On ErrTooMany, keeps what was found before it.
func both(c *addr.Checker, t string, out map[string]bool) error {
	for _, v := range []string{strings.ReplaceAll(t, "\x01", ""), strings.ReplaceAll(t, "\x01", " ")} {
		if err := c.Runs(v, out); err != nil {
			return err
		}
	}
	shown := tags.ReplaceAllString(t, "")
	for _, v := range []string{strings.ReplaceAll(shown, "\x01", ""), strings.ReplaceAll(shown, "\x01", " ")} {
		if err := c.Checked(v, out); err != nil {
			return err
		}
	}
	return nil
}

func emit(w io.Writer, f string, out map[string]bool) {
	lines := make([]string, 0, len(out))
	for k := range out {
		lines = append(lines, k)
	}
	sort.Strings(lines)
	for _, l := range lines {
		fmt.Fprintf(w, "%s\t%s\n", f, l)
	}
}

// JSON scans each JSON file's strings as a reader gets them: \u escapes decoded, every key and
// value, both copies of a duplicate key. Addresses are found as in pages' text: non-ASCII
// dropped, again as a space, and as a reader copying by eye, each also in the order a browser
// shows it (addr.Readings). A bidi control fails the file, as for a page. Reads the first 16 MB.
func JSON(files []string, w io.Writer) error {
	c := addr.New()
	for _, f := range files {
		strs, err := strings16(f)
		if err != nil {
			fmt.Fprintf(w, "%s\t!not JSON (UTF-8) that reads\n", f)
			continue
		}
		out := map[string]bool{}
		c.Start()
		var tooMany error
		for _, s := range strs {
			if strings.ContainsFunc(s, addr.Bidi) {
				out[Bidi] = true
			}
			s = strings.Map(func(r rune) rune {
				switch {
				case r == '\t' || r == '\n' || r == '\f' || r == '\r':
					return ' '
				case r == '<' || r == '>':
					return '-' // punctuation to a reader, like a page's &lt;
				case r < 0x20 || r == 0x7f:
					return -1
				}
				return r
			}, s)
			for _, t := range addr.Readings(s) {
				if tooMany = c.Runs(t, out); tooMany != nil {
					break
				}
			}
			if tooMany != nil {
				break
			}
		}
		if errors.Is(tooMany, addr.ErrTooMany) {
			out["!"+tooMany.Error()] = true
		}
		emit(w, f, out)
	}
	return nil
}

// strings16 returns every key and string value in the JSON file (first 16 MB), in order.
// Errors if it isn't a single JSON value in UTF-8.
func strings16(f string) ([]string, error) {
	h, err := os.Open(f)
	if err != nil {
		return nil, err
	}
	defer h.Close()
	data, err := io.ReadAll(io.LimitReader(h, 16<<20))
	if err != nil {
		return nil, err
	}
	if !utf8.Valid(data) {
		return nil, errors.New("not UTF-8")
	}
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.UseNumber()
	var out []string
	depth, tokens := 0, 0
	for {
		t, err := dec.Token()
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, err
		}
		tokens++
		switch v := t.(type) {
		case string:
			out = append(out, v)
		case json.Delim:
			if v == '{' || v == '[' {
				depth++
			} else {
				depth--
			}
		}
		// One value, and nothing after it
		if depth == 0 && dec.More() {
			return nil, errors.New("more than one value")
		}
	}
	if tokens == 0 || depth != 0 {
		return nil, errors.New("no value, or one not closed")
	}
	return out, nil
}

// NUL prints the files containing a NUL byte, one per line. HTML drops NULs from the text, so
// one could split an address.
func NUL(files []string, w io.Writer) error {
	for _, f := range files {
		b, err := os.ReadFile(f)
		if err != nil {
			return err
		}
		if bytes.IndexByte(b, 0) >= 0 {
			fmt.Fprintln(w, f)
		}
	}
	return nil
}

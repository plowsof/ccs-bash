// Package scan: the addresses in the pages, the feed and the JSON: each file's lines "file<TAB>address", "file<TAB>!reason", and for a page's
// data: images "file<TAB>?qr<TAB>base64" (held back: the site's QR codes are files, qr/).
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
	"unicode/utf8"

	"ccs-check/addr"
)

// Max: a file larger is not read (CCS_GATE_MAX, 8 MB)
func Max() int64 {
	if v, err := strconv.ParseInt(os.Getenv("CCS_GATE_MAX"), 10, 64); err == nil {
		return v
	}
	return 8 << 20
}

// legacy: the named entities a browser reads without their ";" (HTML's table: "&shy" is a soft
// hyphen, which isn't shown, whatever follows it), longest first, as a browser matches them
// (review 11's I-2)
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
	// a data: image of any type, as a browser reads the scheme (any case: review 10's L-2)
	qrs   = regexp.MustCompile(`(?i)data:image/[A-Za-z0-9.+-]*[;,][A-Za-z0-9+/=;,.:%_-]*`)
	tags  = regexp.MustCompile(`<[^>]*>`)
	named = map[string]int{"amp": 38, "lt": 60, "gt": 62, "quot": 34, "apos": 39, "AMP": 38, "LT": 60, "GT": 62, "QUOT": 34}
)

// char: an entity's character: printable ASCII as itself, a space as one, one drawn as an ASCII
// letter or digit as that (addr.Lookalike: &#x430; is a Cyrillic a), anything else \x01 (read
// both ways). A < or > written as an entity is text a browser shows, never markup: read as
// punctuation, an address's groups either side of it are one (review 11's M-1)
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

// number: digits in base as an int; -1 for one too large to be a character (any over 2^31)
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

// code: an entity's character, -1 for none (a name not in named, a number too large)
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

// Bidi: why a file with a bidi control fails, as itself or as an entity: a browser shows the text
// after it in another order than it is written, so an address written backwards, in groups,
// reads the right way round where the checks read it backwards (review 12's M-1)
const Bidi = "!a bidi control (U+202A-202E or U+2066-2069): text shown in another order than it is written"

// bidi: raw has a bidi control as itself (UTF-8), or d (raw as latin-1, its entities still in it)
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

// Pages: a page, feed or JSON as text, read as bytes: it must start as a page or JSON
// does (<, [ or {), or a browser shows it as an image, and have no bidi control; a byte that isn't
// ASCII, or a control character, read twice (dropped, and as a space); entities as a browser
// reads them (&#56; is 8); and, with a character drawn as an ASCII letter or digit (a Cyrillic а,
// a full-width Ａ), read a third time as a reader copying it by eye does (addr.Lookalikes)
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
		// (bytes as latin-1: every byte a character; those not ASCII are \x01 before anything)
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
		emit(w, f, out)
	}
	return nil
}

// both: the addresses of t, read with each \x01 dropped and as a space; then of t as a browser
// lays it out, its tags dropped (an address split between two elements side by side, two tag
// labels or a tag and its count, is one run there), by checksum only. ErrTooMany keeps what was
// found before it
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

// JSON: each JSON file's strings as a reader of it gets them (\u escapes read, every key
// and value, a key twice both), their addresses read as the pages' text is: a character that
// isn't ASCII dropped, and again as a space, and as a reader copying it by eye reads it
// (addr.Lookalikes); a bidi control fails it, as a page's. Its first 16 MB.
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
					return '-' // punctuation to its reader, as a page's &lt; (review 11's M-1)
				case r < 0x20 || r == 0x7f:
					return -1
				}
				return r
			}, s)
			readings := []string{}
			for _, repl := range []rune{-1, ' '} {
				readings = append(readings, strings.Map(func(r rune) rune {
					if r > 0x7f {
						return repl
					}
					return r
				}, s))
			}
			if t, drawn := addr.Lookalikes(s); drawn {
				readings = append(readings, t)
			}
			for _, t := range readings {
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

// strings16: every key and string value in the JSON file (its first 16 MB), in order; an error
// if it isn't one JSON value in UTF-8
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
		// one value, and nothing after it
		if depth == 0 && dec.More() {
			return nil, errors.New("more than one value")
		}
	}
	if tokens == 0 || depth != 0 {
		return nil, errors.New("no value, or one not closed")
	}
	return out, nil
}

// NUL: the files with a NUL byte (HTML drops it from the text, so it could split an address),
// each on a line
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

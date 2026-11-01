// Package scan: the addresses in the pages, the feed and the JSON, as ccs-receive's scan_py and
// json_py read them: each file's lines "file<TAB>address", "file<TAB>!reason", and for a page's
// data: images "file<TAB>?qr<TAB>base64" (the QR codes, read after).
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

var (
	starts   = regexp.MustCompile(`^[ \t\n\r]*[<\[{]`)
	controls = regexp.MustCompile(`[\x00-\x08\x0b\x0e-\x1f\x7f]`)
	entities = regexp.MustCompile(`&#[0-9]+;?|&#[xX][0-9A-Fa-f]+;?|&[A-Za-z][A-Za-z0-9]*;`)
	qrs      = regexp.MustCompile(`data:image/png;base64,[A-Za-z0-9+/]+=*`)
	named    = map[string]int{"amp": 38, "lt": 60, "gt": 62, "quot": 34, "apos": 39}
)

// char: printable ASCII as itself, a space as one, anything else \x01 (read both ways)
func char(n int) string {
	if n > 32 && n < 127 {
		return string(rune(n))
	}
	if n == 9 || n == 10 || n == 12 || n == 13 || n == 32 {
		return " "
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

func entity(e string) string {
	e = strings.TrimSuffix(e, ";")
	switch {
	case strings.HasPrefix(e, "&#x") || strings.HasPrefix(e, "&#X"):
		return char(number(e[3:], 16))
	case strings.HasPrefix(e, "&#"):
		return char(number(e[2:], 10))
	}
	if n, ok := named[e[1:]]; ok {
		return char(n)
	}
	return "\x01"
}

// Pages: scan_py. A page, feed or JSON as text, read as bytes: it must start as a page or JSON
// does (<, [ or {), or a browser shows it as an image; a byte that isn't ASCII, or a control
// character, read twice (dropped, and as a space); entities as a browser reads them (&#56; is 8)
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
		d = entities.ReplaceAllStringFunc(controls.ReplaceAllString(d, "\x01"), entity)
		for _, m := range qrs.FindAllString(d, -1) {
			fmt.Fprintf(w, "%s\t?qr\t%s\n", f, m[22:])
		}
		d = qrs.ReplaceAllString(d, " ")
		if err := both(c, d, out); err != nil {
			out["!"+err.Error()] = true
		}
		emit(w, f, out)
	}
	return nil
}

// both: the addresses of t, read with each \x01 dropped and as a space; ErrTooMany keeps what
// was found before it
func both(c *addr.Checker, t string, out map[string]bool) error {
	c.Start()
	for _, v := range []string{strings.ReplaceAll(t, "\x01", ""), strings.ReplaceAll(t, "\x01", " ")} {
		if err := c.Runs(v, out); err != nil {
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

// JSON: json_py. Each JSON file's strings as a reader of it gets them (\u escapes read, every key
// and value, a key twice both), their addresses read as the pages' text is: a character that
// isn't ASCII dropped, and again as a space. Its first 16 MB, as json_py.
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
			s = strings.Map(func(r rune) rune {
				switch {
				case r == '\t' || r == '\n' || r == '\f' || r == '\r':
					return ' '
				case r < 0x20 || r == 0x7f:
					return -1
				}
				return r
			}, s)
			for _, repl := range []rune{-1, ' '} {
				t := strings.Map(func(r rune) rune {
					if r > 0x7f {
						return repl
					}
					return r
				}, s)
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

package pixels

import (
	"bytes"
	"regexp"
	"testing"
)

var line = regexp.MustCompile(`^[1-9][0-9]{0,3} [1-9][0-9]{0,3} [0-9a-f]{64}$`)

func FuzzOf(f *testing.F) {
	p, _ := grey(f)
	f.Add(p)
	f.Add([]byte("\x89PNG\r\n\x1a\n"))
	f.Fuzz(func(t *testing.T, b []byte) {
		got, err := Of(bytes.NewReader(b))
		if err == nil && !line.MatchString(got) {
			t.Fatalf("%q", got)
		}
	})
}

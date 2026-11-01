package qr

import (
	"bytes"
	"errors"
	"image/gif"
	"image/jpeg"
	"image/png"
	"os"
	"path/filepath"
	"testing"
)

// any bytes as each kind: codes, none, or ErrUnchecked; never a panic (the command recovers
// one, but a panic is a finding)
func FuzzRead(f *testing.F) {
	g := code(f, addr)
	for _, enc := range []func(*bytes.Buffer) error{
		func(b *bytes.Buffer) error { return png.Encode(b, g) },
		func(b *bytes.Buffer) error { return jpeg.Encode(b, g, nil) },
		func(b *bytes.Buffer) error { return gif.Encode(b, pal(g), nil) },
	} {
		var b bytes.Buffer
		enc(&b)
		f.Add(b.Bytes())
	}
	dir := f.TempDir()
	f.Fuzz(func(t *testing.T, b []byte) {
		p := filepath.Join(dir, "f")
		if err := os.WriteFile(p, b, 0o644); err != nil {
			t.Fatal(err)
		}
		for _, kind := range []string{"png", "jpeg", "gif"} {
			if _, err := Read(kind, p, true); err != nil && !errors.Is(err, ErrUnchecked) {
				t.Fatalf("%s: %v", kind, err)
			}
		}
	})
}

package pixels

import (
	"bytes"
	"crypto/sha256"
	"fmt"
	"image/color"
	"image/png"
	"os"
	"regexp"
	"testing"
)

var line = regexp.MustCompile(`^[1-9][0-9]{0,3} [1-9][0-9]{0,3} [0-9a-f]{64}$`)

// any bytes: what Of reads, image/png reads too, to the same pixels (one reading of each PNG)
func FuzzOf(f *testing.F) {
	p, _ := grey(f)
	f.Add(p)
	f.Add([]byte("\x89PNG\r\n\x1a\n"))
	if x, err := os.ReadFile("testdata/X.png"); err == nil {
		f.Add(x)
	}
	f.Fuzz(func(t *testing.T, b []byte) {
		got, err := Of(bytes.NewReader(b))
		if err != nil {
			return
		}
		if !line.MatchString(got) {
			t.Fatalf("%q", got)
		}
		img, err := png.Decode(bytes.NewReader(b))
		if err != nil {
			t.Fatalf("read, as %q; image/png: %v", got, err)
		}
		r := img.Bounds()
		var px []byte
		for y := r.Min.Y; y < r.Max.Y; y++ {
			for x := r.Min.X; x < r.Max.X; x++ {
				c := color.NRGBAModel.Convert(img.At(x, y)).(color.NRGBA)
				px = append(px, c.R, c.G, c.B, c.A)
			}
		}
		if want := fmt.Sprintf("%d %d %x", r.Dx(), r.Dy(), sha256.Sum256(px)); got != want {
			t.Fatalf("%q, image/png %q", got, want)
		}
	})
}

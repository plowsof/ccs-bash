package qr

import (
	"bytes"
	"encoding/binary"
	"errors"
	"hash/crc32"
	"image"
	"image/color"
	"image/draw"
	"image/gif"
	"image/jpeg"
	"image/png"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

var addr = "monero:4" + strings.Repeat("1", 94)

// code: TEXT's QR code as qrencode -s 4 makes it (testdata/: one.png is addr's, two.png
// 4222...'s; the encoder isn't in ccs-check's copy of gozxing)
func code(t testing.TB, text string) *image.Gray {
	name := map[string]string{addr: "one.png", "monero:4" + strings.Repeat("2", 94): "two.png"}[text]
	f, err := os.Open(filepath.Join("testdata", name))
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	img, err := png.Decode(f)
	if err != nil {
		t.Fatal(err)
	}
	return grey(img)
}

func write(t *testing.T, name string, enc func(*bytes.Buffer) error) string {
	var b bytes.Buffer
	if err := enc(&b); err != nil {
		t.Fatal(err)
	}
	p := filepath.Join(t.TempDir(), name)
	if err := os.WriteFile(p, b.Bytes(), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

func pal(g *image.Gray) *image.Paletted {
	p := image.NewPaletted(g.Bounds(), color.Palette{color.Black, color.White})
	draw.Draw(p, p.Bounds(), g, image.Point{}, draw.Src)
	return p
}

func read(t *testing.T, kind, path string, inverted bool) []string {
	got, err := Read(kind, path, inverted)
	if err != nil {
		t.Fatalf("%s: %v", path, err)
	}
	return got
}

func TestFormats(t *testing.T) {
	g := code(t, addr)
	for kind, p := range map[string]string{
		"png":  write(t, "a.png", func(b *bytes.Buffer) error { return png.Encode(b, g) }),
		"jpeg": write(t, "a.jpg", func(b *bytes.Buffer) error { return jpeg.Encode(b, g, &jpeg.Options{Quality: 60}) }),
		"gif":  write(t, "a.gif", func(b *bytes.Buffer) error { return gif.Encode(b, pal(g), nil) }),
	} {
		if got := read(t, kind, p, false); !reflect.DeepEqual(got, []string{addr}) {
			t.Errorf("%s: %q", kind, got)
		}
	}
}

func TestEveryCodeAndFrame(t *testing.T) {
	a, b := code(t, addr), code(t, "monero:4"+strings.Repeat("2", 94))
	two := image.NewGray(image.Rect(0, 0, a.Rect.Dx()*2+40, a.Rect.Dy()))
	draw.Draw(two, two.Bounds(), image.White, image.Point{}, draw.Src)
	draw.Draw(two, a.Bounds(), a, image.Point{}, draw.Src)
	draw.Draw(two, a.Bounds().Add(image.Pt(a.Rect.Dx()+40, 0)), b, image.Point{}, draw.Src)
	p := write(t, "two.png", func(w *bytes.Buffer) error { return png.Encode(w, two) })
	if got := read(t, "png", p, false); len(got) != 2 {
		t.Errorf("two codes in one image: %q", got)
	}
	// a GIF's later frame is read too: a code shown after a blank first frame
	blank := image.NewGray(a.Bounds())
	draw.Draw(blank, blank.Bounds(), image.White, image.Point{}, draw.Src)
	p = write(t, "frames.gif", func(w *bytes.Buffer) error {
		return gif.EncodeAll(w, &gif.GIF{Image: []*image.Paletted{pal(blank), pal(a)}, Delay: []int{100, 100}})
	})
	if got := read(t, "gif", p, false); !reflect.DeepEqual(got, []string{addr}) {
		t.Errorf("the second frame: %q", got)
	}
}

func TestInverted(t *testing.T) {
	g := code(t, addr)
	for i := range g.Pix {
		g.Pix[i] = 255 - g.Pix[i]
	}
	p := write(t, "inv.png", func(b *bytes.Buffer) error { return png.Encode(b, g) })
	if got := read(t, "png", p, false); len(got) != 0 {
		t.Errorf("inverted, read without inverted: %q", got)
	}
	if got := read(t, "png", p, true); !reflect.DeepEqual(got, []string{addr}) {
		t.Errorf("inverted: %q", got)
	}
}

// read as the format its bytes are, as a browser picks the decoder: a JPEG named .png is read;
// an SVG named .png has no codes (no format of the three); an unknown kind an error
func TestKindFromBytes(t *testing.T) {
	g := code(t, addr)
	j := write(t, "j.png", func(b *bytes.Buffer) error { return jpeg.Encode(b, g, nil) })
	if got := read(t, "png", j, true); !reflect.DeepEqual(got, []string{addr}) {
		t.Errorf("a JPEG named .png: %q", got)
	}
	s := write(t, "s.png", func(b *bytes.Buffer) error {
		_, err := b.WriteString(`<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"/>`)
		return err
	})
	if got := read(t, "png", s, true); len(got) != 0 {
		t.Errorf("an SVG as a PNG: %q", got)
	}
	if _, err := Read("bmp", j, false); err == nil {
		t.Error("kind bmp: no error")
	}
}

// images a browser shows with a QR code of 44AF... (review 9, testdata/shown): each is read, or
// unchecked (held back); none is "no code"
func TestAsShown(t *testing.T) {
	for _, c := range []struct{ file, why string }{
		{"apng.png", "APNG: the default image blank, the animation's last frame the code"},
		{"halves.gif", "GIF: two frames, each half the code, drawn one over the other"},
		{"many.gif", "GIF: 101 frames, the code the 101st"},
		{"gif-named.png", "a GIF named .png"},
		{"both.png", "a normal code beside an inverted one"},
		{"nogama.png", "a code of 245 on 255"},
		{"gama.png", "the same with gAMA 0.00455: black on white on screen"},
	} {
		got, err := Read("png", filepath.Join("testdata", "shown", c.file), true)
		if errors.Is(err, ErrUnchecked) {
			continue
		}
		found := false
		for _, s := range got {
			found = found || strings.Contains(s, "44AFFq5kSiGB")
		}
		if err != nil || !found {
			t.Errorf("%s (%s): %q %v", c.file, c.why, got, err)
		}
	}
}

// too large: unchecked, not "no code". A PNG claiming 30000x30000 pixels (its header only),
// and a file over MaxBytes.
func TestLimits(t *testing.T) {
	chunk := func(b *bytes.Buffer, typ string, data []byte) {
		binary.Write(b, binary.BigEndian, uint32(len(data)))
		b.WriteString(typ)
		b.Write(data)
		binary.Write(b, binary.BigEndian, crc32.ChecksumIEEE(append([]byte(typ), data...)))
	}
	p := write(t, "bomb.png", func(b *bytes.Buffer) error {
		b.WriteString("\x89PNG\r\n\x1a\n")
		hdr := make([]byte, 13)
		binary.BigEndian.PutUint32(hdr, 30000)
		binary.BigEndian.PutUint32(hdr[4:], 30000)
		hdr[8] = 8
		chunk(b, "IHDR", hdr)
		chunk(b, "IEND", nil)
		return nil
	})
	if _, err := Read("png", p, true); !errors.Is(err, ErrUnchecked) {
		t.Errorf("30000x30000: %v", err)
	}
	big := write(t, "big.png", func(b *bytes.Buffer) error { _, err := b.Write(make([]byte, MaxBytes+1)); return err })
	if _, err := Read("png", big, true); !errors.Is(err, ErrUnchecked) {
		t.Errorf("over MaxBytes: %v", err)
	}
}

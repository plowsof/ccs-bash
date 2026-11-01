// Package qr: what the QR codes in an image say, as ccs-receive's qrscan_py read them with
// libzbar, here with Go's own decoders (image/png, image/jpeg, image/gif: memory-safe) and
// gozxing's QR reader (ZXing's, in Go: its pinned archive, deps.sh).
package qr

import (
	"bytes"
	"errors"
	"fmt"
	"image"
	"image/color"
	"image/draw"
	"image/gif"
	"image/jpeg"
	"image/png"
	"io"
	"os"

	"github.com/makiuchi-d/gozxing"
	"github.com/makiuchi-d/gozxing/multi/qrcode"
)

const (
	MaxBytes  = 8 << 20  // a larger file is not read (qrscan_py read its first 4 MB: of a larger one, nothing decoded)
	MaxPixels = 40000000 // nor an image (or a GIF frame) larger, as qrscan_py
	MaxFrames = 100      // a GIF's first 100 frames, as qrscan_py
)

// ErrUnchecked: the image could not be checked (too large); not "no QR code"
var ErrUnchecked = errors.New("not checked")

// Read KIND PATH: each QR code's text in the image at PATH, read as KIND (png, jpeg, gif: the
// format its name says, never one picked by its bytes), each frame of a GIF; with inverted, a
// frame where none is found is read again inverted (light on dark, which phones read). An image
// that doesn't decode as KIND has no codes (nil, nil), as qrscan_py; one too large to read is
// ErrUnchecked.
func Read(kind, path string, inverted bool) ([]string, error) {
	data, err := readAtMost(path, MaxBytes)
	if err != nil {
		return nil, err
	}
	frames, err := decode(kind, data)
	if err != nil || len(frames) == 0 {
		return nil, err
	}
	var out []string
	for _, g := range frames {
		got := scan(g)
		if len(got) == 0 && inverted {
			for i := range g.Pix {
				g.Pix[i] = 255 - g.Pix[i]
			}
			got = scan(g)
		}
		out = append(out, got...)
	}
	return out, nil
}

// readAtMost: the file, unless it is larger than max (ErrUnchecked)
func readAtMost(path string, max int64) ([]byte, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	data, err := io.ReadAll(io.LimitReader(f, max+1))
	if err != nil {
		return nil, err
	}
	if int64(len(data)) > max {
		return nil, fmt.Errorf("%w: over %d MB", ErrUnchecked, max>>20)
	}
	return data, nil
}

// decode: the image's frames in 8-bit grey, any transparency laid on white (as a browser on a
// white page); its size from its header first, and nothing larger than MaxPixels decoded
func decode(kind string, data []byte) ([]*image.Gray, error) {
	var conf func(io.Reader) (image.Config, error)
	switch kind {
	case "png":
		conf = png.DecodeConfig
	case "jpeg":
		conf = jpeg.DecodeConfig
	case "gif":
		conf = gif.DecodeConfig
	default:
		return nil, fmt.Errorf("%s: not png, jpeg or gif", kind)
	}
	c, err := conf(bytes.NewReader(data))
	if err != nil {
		return nil, nil // not a KIND: no codes
	}
	if c.Width <= 0 || c.Height <= 0 || int64(c.Width)*int64(c.Height) > MaxPixels {
		return nil, fmt.Errorf("%w: %dx%d pixels, over %d", ErrUnchecked, c.Width, c.Height, MaxPixels)
	}
	var imgs []image.Image
	switch kind {
	case "png", "jpeg":
		var img image.Image
		if kind == "png" {
			img, err = png.Decode(bytes.NewReader(data))
		} else {
			img, err = jpeg.Decode(bytes.NewReader(data))
		}
		if err != nil {
			return nil, nil
		}
		imgs = []image.Image{img}
	case "gif":
		// (each frame is within the screen's size: image/gif refuses one that isn't)
		g, err := gif.DecodeAll(bytes.NewReader(data))
		if err != nil {
			return nil, nil
		}
		for i, f := range g.Image {
			if i == MaxFrames {
				break
			}
			imgs = append(imgs, f)
		}
	}
	out := make([]*image.Gray, 0, len(imgs))
	for _, img := range imgs {
		out = append(out, grey(img))
	}
	return out, nil
}

// grey: img on white, in 8-bit grey
func grey(img image.Image) *image.Gray {
	b := img.Bounds()
	g := image.NewGray(image.Rect(0, 0, b.Dx(), b.Dy()))
	draw.Draw(g, g.Bounds(), image.NewUniform(color.White), image.Point{}, draw.Src)
	draw.Draw(g, g.Bounds(), img, b.Min, draw.Over)
	return g
}

// scan: each QR code's text in g. QR codes only (gozxing's QR readers, no other kind of code's).
// Every code in it (the multi reader; it found all the codes, in a test corpus, that the single
// one did), and without TRY_HARDER: with it, 40 million pixels of noise took 19 s, without it
// 0.6 s. Each code's text as ISO-8859-1, one character a byte, whatever character set it names
// (deps/gozxing.patch: no byte of a multi-byte character hiding the next, "\x81A" being one
// Shift_JIS character).
func scan(g *image.Gray) []string {
	bmp, err := gozxing.NewBinaryBitmapFromImage(g)
	if err != nil {
		return nil
	}
	rs, err := qrcode.NewQRCodeMultiReader().DecodeMultiple(bmp, nil)
	if err != nil {
		return nil
	}
	var out []string
	for _, r := range rs {
		out = append(out, r.GetText())
	}
	return out
}

// Package qr: what the QR codes in an image say, as a browser shows the image: Go's own decoders
// (image/png, image/jpeg, image/gif: memory-safe) and gozxing's QR reader (ZXing's, in Go: its
// pinned archive, deps.sh).
package qr

import (
	"bytes"
	"encoding/binary"
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
	MaxBytes  = 8 << 20  // a larger file is not read
	MaxPixels = 40000000 // nor an image (or a GIF's screen) larger
	MaxFrames = 100      // nor a GIF of more frames
)

// ErrUnchecked: the image could not be checked (too large, an animated PNG, too many frames);
// not "no QR code"
var ErrUnchecked = errors.New("not checked")

// Read KIND PATH: each QR code's text in the image at PATH, as a browser shows it: decoded as
// the format its bytes are (a browser picks the decoder by them, whatever the name says: KIND,
// png, jpeg or gif, is only checked to be one), each frame of a GIF drawn over the ones before
// it, as shown. With inverted, every frame is read inverted too (light on dark, which phones
// read), and with its local contrast raised (a faint code, or one a gamma or colour profile
// makes plain). Bytes of no image format have no codes (nil, nil); an image too large, an
// animated PNG (its frames aren't read) or a GIF of over MaxFrames frames is ErrUnchecked. Each
// text with its NUL bytes dropped (a UTF-16 code's high bytes: a phone shows the rest).
func Read(kind, path string, inverted bool) ([]string, error) {
	if kind != "png" && kind != "jpeg" && kind != "gif" {
		return nil, fmt.Errorf("%s: not png, jpeg or gif", kind)
	}
	data, err := readAtMost(path, MaxBytes)
	if err != nil {
		return nil, err
	}
	var out []string
	seen := map[string]bool{}
	err = frames(data, func(g *image.Gray) {
		views := []*image.Gray{g}
		if inverted {
			c := contrast(g)
			views = append(views, invert(g), c, invert(c))
		}
		for _, v := range views {
			for _, t := range scan(v) {
				t = string(bytes.ReplaceAll([]byte(t), []byte{0}, nil))
				if !seen[t] {
					seen[t] = true
					out = append(out, t)
				}
			}
		}
	})
	return out, err
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

// sniff: the format of data by its first bytes, as a browser picks it; "" for none of the three
func sniff(data []byte) string {
	switch {
	case bytes.HasPrefix(data, []byte("\x89PNG\r\n\x1a\n")):
		return "png"
	case bytes.HasPrefix(data, []byte("\xff\xd8\xff")):
		return "jpeg"
	case bytes.HasPrefix(data, []byte("GIF87a")), bytes.HasPrefix(data, []byte("GIF89a")):
		return "gif"
	}
	return ""
}

// animated: a PNG with an acTL chunk (an APNG): a browser plays frames image/png never decodes
func animated(data []byte) bool {
	for i := 8; i+8 <= len(data); {
		n := int64(binary.BigEndian.Uint32(data[i:]))
		switch string(data[i+4 : i+8]) {
		case "acTL":
			return true
		case "IDAT", "IEND":
			return false // (acTL comes before the image data)
		}
		if n > int64(len(data)-i-12) {
			return false
		}
		i += 12 + int(n)
	}
	return false
}

// frames: each of the image's frames as shown, in 8-bit grey, any transparency laid on white (as
// a browser on a white page), to fn in turn; its size from its header first, and nothing larger
// than MaxPixels decoded
func frames(data []byte, fn func(*image.Gray)) error {
	kind := sniff(data)
	var conf func(io.Reader) (image.Config, error)
	switch kind {
	case "png":
		if animated(data) {
			return fmt.Errorf("%w: an animated PNG", ErrUnchecked)
		}
		conf = png.DecodeConfig
	case "jpeg":
		conf = jpeg.DecodeConfig
	case "gif":
		conf = gif.DecodeConfig
	default:
		return nil // no image a browser shows: no codes
	}
	c, err := conf(bytes.NewReader(data))
	if err != nil {
		return nil
	}
	if c.Width <= 0 || c.Height <= 0 || int64(c.Width)*int64(c.Height) > MaxPixels {
		return fmt.Errorf("%w: %dx%d pixels, over %d", ErrUnchecked, c.Width, c.Height, MaxPixels)
	}
	switch kind {
	case "png", "jpeg":
		var img image.Image
		if kind == "png" {
			img, err = png.Decode(bytes.NewReader(data))
		} else {
			img, err = jpeg.Decode(bytes.NewReader(data))
		}
		if err != nil {
			return nil
		}
		fn(grey(img))
		return nil
	}
	g, err := gif.DecodeAll(bytes.NewReader(data))
	if err != nil {
		return nil
	}
	if len(g.Image) > MaxFrames {
		return fmt.Errorf("%w: %d frames, over %d", ErrUnchecked, len(g.Image), MaxFrames)
	}
	composite(g, fn)
	return nil
}

// composite: each frame of g as a browser shows it, to fn: drawn over the screen as the frames
// before it left it (each frame's disposal: kept, cleared to transparent, or put back as before)
func composite(g *gif.GIF, fn func(*image.Gray)) {
	screen := image.NewRGBA(image.Rect(0, 0, g.Config.Width, g.Config.Height))
	for i, f := range g.Image {
		var disposal byte
		if i < len(g.Disposal) {
			disposal = g.Disposal[i]
		}
		var before *image.RGBA
		if disposal == gif.DisposalPrevious {
			before = image.NewRGBA(screen.Rect)
			copy(before.Pix, screen.Pix)
		}
		draw.Draw(screen, f.Bounds(), f, f.Bounds().Min, draw.Over)
		fn(grey(screen))
		switch disposal {
		case gif.DisposalBackground:
			draw.Draw(screen, f.Bounds(), image.Transparent, image.Point{}, draw.Src)
		case gif.DisposalPrevious:
			screen = before
		}
	}
}

// grey: img on white, in 8-bit grey
func grey(img image.Image) *image.Gray {
	b := img.Bounds()
	g := image.NewGray(image.Rect(0, 0, b.Dx(), b.Dy()))
	draw.Draw(g, g.Bounds(), image.NewUniform(color.White), image.Point{}, draw.Src)
	draw.Draw(g, g.Bounds(), img, b.Min, draw.Over)
	return g
}

func invert(g *image.Gray) *image.Gray {
	v := image.NewGray(g.Rect)
	for i, p := range g.Pix {
		v.Pix[i] = 255 - p
	}
	return v
}

// contrast: g with its local contrast raised: each pixel's difference from the mean of the square
// around it (a sixteenth of the shorter side each way, 16 pixels at least) times 12, around
// mid-grey. A code of 245 on 255, which the reader takes for blank (it needs a range of 24),
// becomes black on white; so does one a gamma or colour profile makes plain on screen, while the
// curve keeps the greys' order (one that doesn't, any value to any, isn't caught).
func contrast(g *image.Gray) *image.Gray {
	w, h := g.Rect.Dx(), g.Rect.Dy()
	r := max(16, min(w, h)/16)
	// each row's sums over x-r..x+r, then a running sum of those over y-r..y+r a column (in 32
	// bits: 255 * (2r+1)^2 fits, r at most a sixteenth of a side of 40 million pixels)
	rows := make([]uint32, w*h)
	for y := 0; y < h; y++ {
		var s uint32
		p := g.Pix[y*g.Stride : y*g.Stride+w]
		for x := 0; x <= min(r, w-1); x++ {
			s += uint32(p[x])
		}
		for x := 0; x < w; x++ {
			rows[y*w+x] = s
			if x+r+1 < w {
				s += uint32(p[x+r+1])
			}
			if x-r >= 0 {
				s -= uint32(p[x-r])
			}
		}
	}
	col := make([]uint32, w)
	for y := 0; y <= min(r, h-1); y++ {
		for x := 0; x < w; x++ {
			col[x] += rows[y*w+x]
		}
	}
	out := image.NewGray(g.Rect)
	for y := 0; y < h; y++ {
		ny := int64(min(h, y+r+1) - max(0, y-r))
		for x := 0; x < w; x++ {
			n := ny * int64(min(w, x+r+1)-max(0, x-r))
			v := 128 + 12*(int64(g.Pix[y*g.Stride+x])-int64(col[x])/n)
			out.Pix[y*out.Stride+x] = byte(min(255, max(0, v)))
		}
		if y+r+1 < h {
			for x := 0; x < w; x++ {
				col[x] += rows[(y+r+1)*w+x]
			}
		}
		if y-r >= 0 {
			for x := 0; x < w; x++ {
				col[x] -= rows[(y-r)*w+x]
			}
		}
	}
	return out
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

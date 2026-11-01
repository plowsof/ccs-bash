// Package pixels: a PNG's pixels as a browser shows them, as ccs-receive's pixels_py read them:
// only the chunks and formats qrencode writes (no animated PNG's frames, no gamma or colour
// profile that could show something else), then "<width> <height> <sha256 of its RGBA pixels>".
// Its own reader, not image/png: one that refuses everything qrencode doesn't write.
package pixels

import (
	"bytes"
	"compress/zlib"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
)

var errPNG = errors.New("not a PNG qrencode could have written")

// Of: "<width> <height> <sha256 of its RGBA pixels>" of the PNG (its first 4 MB, as pixels_py)
func Of(r io.Reader) (string, error) {
	d, err := io.ReadAll(io.LimitReader(r, 4<<20))
	if err != nil {
		return "", err
	}
	if !bytes.HasPrefix(d, []byte("\x89PNG\r\n\x1a\n")) {
		return "", errPNG
	}
	// the chunks, as pixels_py walks them: their CRCs not read (the pixels are what's compared),
	// the last IHDR, PLTE and tRNS the ones that count, up to IEND
	var idat, plte, trns, hdr []byte
	for i := 8; ; {
		if i+8 > len(d) {
			return "", errPNG
		}
		n := int(binary.BigEndian.Uint32(d[i:]))
		t := string(d[i+4 : i+8])
		if n > len(d)-(i+8) {
			return "", errPNG
		}
		c := d[i+8 : i+8+n]
		i += 12 + n
		switch t {
		case "IHDR":
			if len(c) != 13 {
				return "", errPNG
			}
			hdr = c
		case "PLTE":
			plte = c
		case "tRNS":
			trns = c
		case "pHYs":
		case "IDAT":
			idat = append(idat, c...)
		case "IEND":
		default:
			return "", errPNG
		}
		if t == "IEND" {
			break
		}
	}
	if hdr == nil {
		return "", errPNG
	}
	w, h := int(binary.BigEndian.Uint32(hdr)), int(binary.BigEndian.Uint32(hdr[4:]))
	depth, kind, interlace := int(hdr[8]), int(hdr[9]), hdr[12]
	formats := map[[2]int]bool{{0, 1}: true, {0, 8}: true, {3, 1}: true, {3, 8}: true, {2, 8}: true, {6, 8}: true}
	if w <= 0 || w > 4096 || h <= 0 || h > 4096 || interlace != 0 || !formats[[2]int{kind, depth}] {
		return "", errPNG
	}
	ch := map[int]int{0: 1, 3: 1, 2: 3, 6: 4}[kind]
	stride := (w*ch*depth + 7) / 8
	bpp := max(1, ch*depth/8)
	z, err := zlib.NewReader(bytes.NewReader(idat))
	if err != nil {
		return "", errPNG
	}
	raw, err := io.ReadAll(io.LimitReader(z, int64(h*(stride+1)+1)))
	if err != nil && !errors.Is(err, io.ErrUnexpectedEOF) || len(raw) != h*(stride+1) {
		return "", errPNG
	}
	out := make([]byte, 0, w*h*4)
	prev, row := make([]byte, stride), make([]byte, stride)
	for y := 0; y < h; y++ {
		f := raw[y*(stride+1)]
		copy(row, raw[y*(stride+1)+1:(y+1)*(stride+1)])
		for x := 0; x < stride; x++ {
			var a, b, c int
			if x >= bpp {
				a, c = int(row[x-bpp]), int(prev[x-bpp])
			}
			b = int(prev[x])
			switch f {
			case 0:
			case 1:
				row[x] += byte(a)
			case 2:
				row[x] += byte(b)
			case 3:
				row[x] += byte((a + b) / 2)
			case 4:
				p := a + b - c
				pa, pb, pc := abs(p-a), abs(p-b), abs(p-c)
				if pa <= pb && pa <= pc {
					row[x] += byte(a)
				} else if pb <= pc {
					row[x] += byte(b)
				} else {
					row[x] += byte(c)
				}
			default:
				return "", errPNG
			}
		}
		prev, row = row, prev
		for x := 0; x < w; x++ {
			var v int
			if depth == 1 {
				v = int(prev[x>>3]>>(7-(x&7))) & 1
			} else {
				v = int(prev[x*ch])
			}
			switch kind {
			case 3:
				if 3*v+3 > len(plte) {
					return "", errPNG
				}
				alpha := byte(255)
				if v < len(trns) {
					alpha = trns[v]
				}
				out = append(out, plte[3*v], plte[3*v+1], plte[3*v+2], alpha)
			case 0:
				g := v
				if depth == 1 {
					g = v * 255
				}
				alpha := byte(255)
				if len(trns) == 2 && int(binary.BigEndian.Uint16(trns)) == v {
					alpha = 0
				}
				out = append(out, byte(g), byte(g), byte(g), alpha)
			case 2:
				if trns != nil {
					return "", errPNG
				}
				out = append(out, prev[x*3], prev[x*3+1], prev[x*3+2], 255)
			default:
				out = append(out, prev[x*4:x*4+4]...)
			}
		}
	}
	return fmt.Sprintf("%d %d %x", w, h, sha256.Sum256(out)), nil
}

func abs(n int) int {
	if n < 0 {
		return -n
	}
	return n
}

package pixels

import (
	"bytes"
	"crypto/sha256"
	"encoding/binary"
	"fmt"
	"hash/crc32"
	"image"
	"image/png"
	"os"
	"testing"
)

func grey(t testing.TB) ([]byte, string) {
	g := image.NewGray(image.Rect(0, 0, 5, 3))
	var rgba []byte
	for i := range g.Pix {
		g.Pix[i] = byte(i * 17)
		rgba = append(rgba, byte(i*17), byte(i*17), byte(i*17), 255)
	}
	var b bytes.Buffer
	if err := png.Encode(&b, g); err != nil {
		t.Fatal(err)
	}
	return b.Bytes(), fmt.Sprintf("5 3 %x", sha256.Sum256(rgba))
}

func TestGrey(t *testing.T) {
	p, want := grey(t)
	if got, err := Of(bytes.NewReader(p)); err != nil || got != want {
		t.Errorf("%q %v, want %q", got, err, want)
	}
}

// a chunk qrencode doesn't write (gAMA: a browser would show other colours), before IDAT
func TestRefused(t *testing.T) {
	p, _ := grey(t)
	gama := make([]byte, 4)
	binary.BigEndian.PutUint32(gama, 45455)
	var c bytes.Buffer
	binary.Write(&c, binary.BigEndian, uint32(4))
	c.WriteString("gAMA")
	c.Write(gama)
	binary.Write(&c, binary.BigEndian, crc32.ChecksumIEEE(append([]byte("gAMA"), gama...)))
	at := 8 + 25 // the signature, IHDR
	q := append(append(append([]byte{}, p[:at]...), c.Bytes()...), p[at:]...)
	for name, b := range map[string][]byte{"gAMA": q, "not a PNG": []byte("GIF89a"), "cut short": p[:len(p)-20]} {
		if got, err := Of(bytes.NewReader(b)); err == nil {
			t.Errorf("%s: read: %q", name, got)
		}
	}
}

// read as another decoder reads them, or not at all (review 9): twoplte.png has two PLTEs, the
// first drawing another code, the last X.png's (qrencode's of a listed address, which it hashes
// to); a CRC wrong; qrencode's own PNG read
func TestOneReading(t *testing.T) {
	x, two := file(t, "X.png"), file(t, "twoplte.png")
	if _, err := Of(bytes.NewReader(x)); err != nil {
		t.Errorf("qrencode's: %v", err)
	}
	bad := append([]byte{}, x...)
	bad[len(bad)-1] ^= 1 // IEND's CRC
	for name, b := range map[string][]byte{"two PLTEs": two, "a CRC wrong": bad} {
		if got, err := Of(bytes.NewReader(b)); err == nil {
			t.Errorf("%s: read: %q", name, got)
		}
	}
}

func file(t *testing.T, name string) []byte {
	b, err := os.ReadFile("testdata/" + name)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

// Package addr finds Monero addresses: base58 in Monero's blocks, the network prefix, and the
// Keccak-256 checksum. It also finds addresses written in groups ("4A9b xZq3"), kept only where
// the checksum confirms them, within a budget of checksums and time.
package addr

import (
	"errors"
	"math/bits"
	"os"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// Alphabet is base58 as Monero (and Bitcoin) uses it: no 0, O, I or l
const Alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

// ErrTooMany means the budget ran out (CCS_GATE_KECCAK checksums or CCS_GATE_SECS seconds, per file)
var ErrTooMany = errors.New("too many runs that could be addresses to check")

var rc = [24]uint64{1, 0x8082, 0x800000000000808a, 0x8000000080008000, 0x808b, 0x80000001, 0x8000000080008081,
	0x8000000000008009, 0x8a, 0x88, 0x80008009, 0x8000000a, 0x8000808b, 0x800000000000008b,
	0x8000000000008089, 0x8000000000008003, 0x8000000000008002, 0x8000000000000080, 0x800a,
	0x800000008000000a, 0x8000000080008081, 0x8000000000008080, 0x80000001, 0x8000000080008008}
var rot = [5][5]int{{0, 36, 3, 41, 18}, {1, 44, 10, 45, 2}, {62, 6, 43, 15, 61}, {28, 55, 25, 21, 56}, {27, 20, 39, 8, 14}}

// Keccak256 is Keccak-256 as Monero uses it (the original padding, not SHA-3's)
func Keccak256(b []byte) [32]byte {
	p := append(append([]byte{}, b...), 1)
	for len(p)%136 != 0 {
		p = append(p, 0)
	}
	p[len(p)-1] |= 0x80
	var s [5][5]uint64
	for o := 0; o < len(p); o += 136 {
		for i := 0; i < 17; i++ {
			var v uint64
			for k := 7; k >= 0; k-- {
				v = v<<8 | uint64(p[o+8*i+k])
			}
			s[i%5][i/5] ^= v
		}
		for _, r := range rc {
			var c, d [5]uint64
			for x := 0; x < 5; x++ {
				c[x] = s[x][0] ^ s[x][1] ^ s[x][2] ^ s[x][3] ^ s[x][4]
			}
			for x := 0; x < 5; x++ {
				d[x] = c[(x+4)%5] ^ bits.RotateLeft64(c[(x+1)%5], 1)
			}
			var t [5][5]uint64
			for x := 0; x < 5; x++ {
				for y := 0; y < 5; y++ {
					t[y][(2*x+3*y)%5] = bits.RotateLeft64(s[x][y]^d[x], rot[x][y])
				}
			}
			for x := 0; x < 5; x++ {
				for y := 0; y < 5; y++ {
					s[x][y] = t[x][y] ^ (^t[(x+1)%5][y] & t[(x+2)%5][y])
				}
			}
			s[0][0] ^= r
		}
	}
	var out [32]byte
	for i := 0; i < 4; i++ {
		for k := 0; k < 8; k++ {
			out[8*i+k] = byte(s[i%5][i/5] >> (8 * k))
		}
	}
	return out
}

// Bytes in a last block of n characters (n: 0..11); -1 for an impossible length
var size = [12]int{0, -1, 1, 2, -1, 3, 4, 5, -1, 6, 7, 8}

// B58 decodes Monero's base58: blocks of 11 characters for 8 bytes. ok is false for an
// impossible block length, or a value too big for its bytes. s must be base58 characters only.
func B58(s string) ([]byte, bool) {
	var out []byte
	for i := 0; i < len(s); i += 11 {
		blk := s[i:min(i+11, len(s))]
		k := size[len(blk)]
		if k < 0 {
			return nil, false
		}
		// 11 characters can reach 58^11 (> 2^64), so use 128 bits
		var hi, lo uint64
		for j := 0; j < len(blk); j++ {
			v := uint64(strings.IndexByte(Alphabet, blk[j]))
			h1, l1 := bits.Mul64(lo, 58)
			var carry uint64
			lo, carry = bits.Add64(l1, v, 0)
			hi = hi*58 + h1 + carry
		}
		if hi != 0 || (k < 8 && lo>>(8*k) != 0) {
			return nil, false
		}
		for b := k - 1; b >= 0; b-- {
			out = append(out, byte(lo>>(8*b)))
		}
	}
	return out, true
}

// Monero's network prefixes (an address's first byte): standard, subaddress and integrated, for
// mainnet, testnet and stagenet
var nets = map[byte]bool{18: true, 19: true, 24: true, 25: true, 36: true, 42: true, 53: true, 54: true, 63: true}

// Checker holds a budget of checksums and time, reset per file by Start, and a cache of checksums
// already computed (kept across files, so a repeat is free).
type Checker struct {
	Budget int
	Secs   time.Duration
	n      int
	t0     time.Time
	seen   map[string]bool
}

// New reads the budget from CCS_GATE_KECCAK (3000) and CCS_GATE_SECS (20)
func New() *Checker {
	c := &Checker{Budget: 3000, Secs: 20 * time.Second, seen: map[string]bool{}}
	if v, err := strconv.Atoi(os.Getenv("CCS_GATE_KECCAK")); err == nil {
		c.Budget = v
	}
	if v, err := strconv.ParseFloat(os.Getenv("CCS_GATE_SECS"), 64); err == nil {
		c.Secs = time.Duration(v * float64(time.Second))
	}
	return c
}

// Start resets the budget for a new file
func (c *Checker) Start() { c.n, c.t0 = 0, time.Now() }

// Valid reports whether s (base58 characters only) is an address with a valid checksum and a
// known network prefix. Returns ErrTooMany past the budget. Each new checksum costs one.
func (c *Checker) Valid(s string) (bool, error) {
	if !strings.ContainsRune("45789AB", rune(s[0])) {
		return false, nil
	}
	if h, ok := B58(s[:min(11, len(s))]); !ok || len(h) == 0 || !nets[h[0]] {
		return false, nil
	}
	if v, ok := c.seen[s]; ok {
		return v, nil
	}
	d, ok := B58(s)
	if !ok || !nets[d[0]] {
		return false, nil
	}
	c.n++
	if c.n > c.Budget || time.Since(c.t0) > c.Secs {
		return false, ErrTooMany
	}
	sum := Keccak256(d[:len(d)-4])
	v := string(sum[:4]) == string(d[len(d)-4:])
	c.seen[s] = v
	return v, nil
}

// A run of base58 in groups, split by 1 to 3 characters that can't be in an address. Not 0, O, I
// or l (a reader would take them for address characters), and not < > or \x01.
var groups = regexp.MustCompile(`[1-9A-HJ-NP-Za-km-z]+(?:[^1-9A-HJ-NP-Za-km-z0OIl<>\x01]{1,3}[1-9A-HJ-NP-Za-km-z]+)+`)
var spaces = regexp.MustCompile(`\s+`)
var notB58 = regexp.MustCompile(`[^1-9A-HJ-NP-Za-km-z]`)

// Grouped adds to out the addresses written in groups in t (ASCII). Groups are joined, and any
// 95 or 106 characters in a run with a valid checksum count. Adds only once all of t is read;
// past the budget, adds none of t's.
func (c *Checker) Grouped(t string, out map[string]bool) error {
	found := map[string]bool{}
	for _, g := range groups.FindAllString(spaces.ReplaceAllString(t, " "), -1) {
		j := notB58.ReplaceAllString(g, "")
		for _, n := range []int{95, 106} {
			for i := 0; i+n <= len(j); i++ {
				ok, err := c.Valid(j[i : i+n])
				if err != nil {
					return err
				}
				if ok {
					found[j[i:i+n]] = true
				}
			}
		}
	}
	for a := range found {
		out[a] = true
	}
	return nil
}

// Checked adds to out the addresses in t with a valid checksum: any 95 or 106 characters of a
// base58 run, plus Grouped's. For text joined from pieces (a page's elements laid side by side),
// where Runs' "any 95 letters and digits" could be words that only meet there. Like Grouped, it
// adds only once all of t is read.
func (c *Checker) Checked(t string, out map[string]bool) error {
	found := map[string]bool{}
	for _, r := range long.FindAllString(t, -1) {
		for _, n := range []int{95, 106} {
			for i := 0; i+n <= len(r); i++ {
				ok, err := c.Valid(r[i : i+n])
				if err != nil {
					return err
				}
				if ok {
					found[r[i:i+n]] = true
				}
			}
		}
	}
	if err := c.Grouped(t, found); err != nil {
		return err
	}
	for a := range found {
		out[a] = true
	}
	return nil
}

var long = regexp.MustCompile(`[1-9A-HJ-NP-Za-km-z]{95,}`)

var token = regexp.MustCompile(`[0-9A-Za-z]+`)

// Runs returns every run of 95 or 106 letters and digits in t without 0, O, I or l, plus
// Grouped's. The checksum is not checked, so an address one character off is still caught.
func (c *Checker) Runs(t string, out map[string]bool) error {
	for _, w := range token.FindAllString(t, -1) {
		if (len(w) == 95 || len(w) == 106) && !strings.ContainsAny(w, "0OIl") {
			out[w] = true
		}
	}
	return c.Grouped(t, out)
}

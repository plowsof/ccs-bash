// Package addr: Monero addresses as ccs-receive's check_py read them: base58 in Monero's blocks,
// the network's prefix, the Keccak-256 checksum; and addresses written in groups ("4A9b xZq3"),
// kept only where the checksum says they are one, within a budget of checksums and of time.
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

// Alphabet: base58 as Monero (and Bitcoin) has it: no 0, O, I or l
const Alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

// ErrTooMany: past the budget (CCS_GATE_KECCAK checksums, CCS_GATE_SECS seconds, per file)
var ErrTooMany = errors.New("too many runs that could be addresses to check")

var rc = [24]uint64{1, 0x8082, 0x800000000000808a, 0x8000000080008000, 0x808b, 0x80000001, 0x8000000080008081,
	0x8000000000008009, 0x8a, 0x88, 0x80008009, 0x8000000a, 0x8000808b, 0x800000000000008b,
	0x8000000000008089, 0x8000000000008003, 0x8000000000008002, 0x8000000000000080, 0x800a,
	0x800000008000000a, 0x8000000080008081, 0x8000000000008080, 0x80000001, 0x8000000080008008}
var rot = [5][5]int{{0, 36, 3, 41, 18}, {1, 44, 10, 45, 2}, {62, 6, 43, 15, 61}, {28, 55, 25, 21, 56}, {27, 20, 39, 8, 14}}

// Keccak256: Keccak-256 as Monero has it (the original padding, not SHA-3's), as check_py's
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

// the bytes of a last block of n characters (n: 0..11), -1 for a length no block has
var size = [12]int{0, -1, 1, 2, -1, 3, 4, 5, -1, 6, 7, 8}

// B58: base58 as Monero has it, blocks of 11 characters for 8 bytes; ok false for a block of a
// length none has, or a value over its bytes (s: base58 characters only, as check_py's callers)
func B58(s string) ([]byte, bool) {
	var out []byte
	for i := 0; i < len(s); i += 11 {
		blk := s[i:min(i+11, len(s))]
		k := size[len(blk)]
		if k < 0 {
			return nil, false
		}
		// 11 characters: up to 58^11 (> 2^64), so in 128 bits
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

// the networks Monero has, by their prefix (an address's first byte): main, sub and integrated
// addresses of mainnet, testnet and stagenet
var nets = map[byte]bool{18: true, 19: true, 24: true, 25: true, 36: true, 42: true, 53: true, 54: true, 63: true}

// Checker: a budget of checksums and of time (check_py's spent), reset per file by Start, and
// the checksums already made (kept across files, as check_py's seen_valid: one seen again is free)
type Checker struct {
	Budget int
	Secs   time.Duration
	n      int
	t0     time.Time
	seen   map[string]bool
}

// New: the budget from CCS_GATE_KECCAK (3000) and CCS_GATE_SECS (20), as check_py
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

// Start: a new file's budget
func (c *Checker) Start() { c.n, c.t0 = 0, time.Now() }

// Valid: s (base58 characters only) is an address its checksum says is one, of a network Monero
// has; ErrTooMany past the budget. Each new checksum costs one.
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

// a run of base58 in groups: split by 1 to 3 characters that can't be in one (not base58, not
// 0, O, I or l, which a reader would take for one, nor < > or \x01)
var groups = regexp.MustCompile(`[1-9A-HJ-NP-Za-km-z]+(?:[^1-9A-HJ-NP-Za-km-z0OIl<>\x01]{1,3}[1-9A-HJ-NP-Za-km-z]+)+`)
var spaces = regexp.MustCompile(`\s+`)
var notB58 = regexp.MustCompile(`[^1-9A-HJ-NP-Za-km-z]`)

// Grouped: the addresses written in groups in t (ASCII), joined, each 95 or 106 characters
// anywhere in a group's run that its checksum says is one, as check_py's grouped: added to out
// only when all of t is read (past the budget, none of t's)
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

// Checked: the addresses in t its checksum says are ones: any 95 or 106 characters of a run of
// base58, and Grouped's. For text joined from pieces (a page's elements laid side by side), where
// Runs' "any 95 letters and digits" could be words that only meet there; added to out only when
// all of t is read, as Grouped's
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

// Runs: every run of 95 or 106 letters and digits in t with no 0, O, I or l (an address as it
// is written, its checksum not asked: one a character off is still kept), and Grouped's
func (c *Checker) Runs(t string, out map[string]bool) error {
	for _, w := range token.FindAllString(t, -1) {
		if (len(w) == 95 || len(w) == 106) && !strings.ContainsAny(w, "0OIl") {
			out[w] = true
		}
	}
	return c.Grouped(t, out)
}

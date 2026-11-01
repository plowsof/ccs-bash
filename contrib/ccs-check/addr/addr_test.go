package addr

import (
	"encoding/hex"
	"errors"
	"strings"
	"testing"
)

// the Monero General Fund's address: a real checksum
const fund = "44AFFq5kSiGBoZ4NMDwYtN18obc8AemS33DBLWs3H7otXft3XjrpDtQGv7SqSsaBYBb98uNbr2VBBEt7f2wfn3RVGQBEP3A"

func TestKeccak256(t *testing.T) {
	for in, want := range map[string]string{
		"":    "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
		"abc": "4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45",
		// two blocks (136 bytes and more)
		strings.Repeat("a", 200): "",
	} {
		got := Keccak256([]byte(in))
		if want != "" && hex.EncodeToString(got[:]) != want {
			t.Errorf("keccak(%q) = %x", in, got)
		}
	}
}

func TestB58(t *testing.T) {
	d, ok := B58(fund)
	if !ok || len(d) != 69 || d[0] != 18 {
		t.Fatalf("the fund's address: %v %d %x", ok, len(d), d[:1])
	}
	for _, s := range []string{"1", "1111", "11111111", "zzzzzzzzzzz"} {
		if _, ok := B58(s); ok {
			t.Errorf("%q: read, a block no address has or a value over its bytes", s)
		}
	}
}

func TestValid(t *testing.T) {
	c := New()
	c.Start()
	if ok, err := c.Valid(fund); !ok || err != nil {
		t.Errorf("the fund's address: %v %v", ok, err)
	}
	off := fund[:94] + "B"
	if ok, _ := c.Valid(off); ok {
		t.Error("a character off: valid")
	}
	if ok, _ := c.Valid("3" + fund[1:]); ok {
		t.Error("not a network's first character: valid")
	}
}

func TestGrouped(t *testing.T) {
	c := New()
	c.Start()
	var parts []string
	for i := 0; i < len(fund); i += 4 {
		parts = append(parts, fund[i:min(i+4, len(fund))])
	}
	for _, sep := range []string{" ", " - ", "/", "\n\t "} {
		out := map[string]bool{}
		if err := c.Grouped("send to "+strings.Join(parts, sep)+" please", out); err != nil || !out[fund] {
			t.Errorf("split by %q: %v %v", sep, out, err)
		}
	}
	for _, sep := range []string{"----", "<", "0", "\x01"} { // (whitespace is one space, however long)
		out := map[string]bool{}
		c.Grouped(strings.Join(parts, sep), out)
		if out[fund] {
			t.Errorf("split by %q: read joined", sep)
		}
	}
}

func TestBudget(t *testing.T) {
	c := New()
	c.Budget = 2
	c.Start()
	// runs that pass the network check, each a checksum: past 2, ErrTooMany, and nothing of it kept
	text := strings.Repeat("4"+strings.Repeat("A", 94)+" ", 5)
	out := map[string]bool{}
	if err := c.Grouped(text+fund, out); !errors.Is(err, ErrTooMany) || len(out) != 0 {
		t.Errorf("past the budget: %v %v", err, out)
	}
}

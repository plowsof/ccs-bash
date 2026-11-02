package main

import (
	"errors"
	"fmt"
	"io"
	"os"
	"syscall"
	"time"

	"ccs-check/qr"
)

func init() { commands["qr"] = qrCmd }

// qr KIND IMAGE [inverted]: each QR code's text in IMAGE on a line, as a browser shows it (qr.Read),
// exit 1 if there is none (or IMAGE is no image); exit 2 (the reason on stderr) when it couldn't
// be checked: too large, animated, out of time (15 s) or memory (1 GB), or a fault in the
// decoders. Never "none" for an image it didn't read to the end. (A test's: with
// CCS_GATE_SCANLOG, each image read is noted there: its kind and first bytes.)
func qrCmd(args []string) int {
	if len(args) < 2 || len(args) > 3 || (len(args) == 3 && args[2] != "inverted") {
		fmt.Fprintln(os.Stderr, "usage: ccs-check qr png|jpeg|gif IMAGE [inverted]")
		return 2
	}
	// 1 GB at most, the decoders' too: a GIF's frames are all decoded before any is read. (Of
	// memory written, RLIMIT_DATA: Go reserves address space it never uses, under RLIMIT_AS it fails)
	lim := syscall.Rlimit{Cur: 1 << 30, Max: 1 << 30}
	if err := syscall.Setrlimit(syscall.RLIMIT_DATA, &lim); err != nil {
		fmt.Fprintln(os.Stderr, "ccs-check qr: no memory limit:", err)
		return 2
	}
	if log := os.Getenv("CCS_GATE_SCANLOG"); log != "" {
		scanlog(log, args[0], args[1])
	}
	type result struct {
		texts []string
		err   error
	}
	done := make(chan result, 1)
	go func() {
		defer func() {
			if p := recover(); p != nil {
				done <- result{err: fmt.Errorf("the decoder failed: %v", p)}
			}
		}()
		t, err := qr.Read(args[0], args[1], len(args) == 3)
		done <- result{t, err}
	}()
	var r result
	select {
	case r = <-done:
	case <-time.After(15 * time.Second):
		r.err = errors.New("not read in 15 s")
	}
	if r.err != nil {
		fmt.Fprintln(os.Stderr, "ccs-check qr:", args[1]+":", r.err)
		return 2
	}
	for _, t := range r.texts {
		os.Stdout.WriteString(t + "\n")
	}
	if len(r.texts) == 0 {
		return 1
	}
	return 0
}

// scanlog LOG KIND PATH: "<PATH's first 4 bytes> KIND" on a line of LOG, each byte printable
// ASCII as itself, else as 3 octal digits (as qrscan_py wrote it)
func scanlog(log, kind, path string) {
	head := make([]byte, 4)
	if f, err := os.Open(path); err == nil {
		n, _ := io.ReadFull(f, head)
		head = head[:n]
		f.Close()
	}
	line := ""
	for _, b := range head {
		if b > 32 && b < 127 {
			line += string(rune(b))
		} else {
			line += fmt.Sprintf("%03o", b)
		}
	}
	if f, err := os.OpenFile(log, os.O_WRONLY|os.O_APPEND, 0); err == nil {
		fmt.Fprintln(f, line+" "+kind)
		f.Close()
	}
}

package main

import (
	"bufio"
	"fmt"
	"os"
	"syscall"

	"ccs-check/pages"
)

func init() { commands["pages"] = pagesCmd }

// pages SITE DESIGNS BODIES LIST VIEWKEY HOSTS ONION < pages (NUL-separated, relative to SITE):
// as pages_py, "page<TAB>=ok" for each page that passes, after "page<TAB>=box<TAB>address<TAB>QR
// code base64" for its donation box; else "page<TAB>!reason". Exit 2, nothing printed, if the
// list, the proposals' renderings or a design can't be read (pages_py stopped there too).
func pagesCmd(args []string) int {
	if len(args) != 7 {
		fmt.Fprintln(os.Stderr, "usage: ccs-check pages SITE DESIGNS BODIES LIST VIEWKEY HOSTS ONION < pages")
		return 2
	}
	// 1 GB at most (of memory written, RLIMIT_DATA, as qr): matching a page takes memory as it goes
	lim := syscall.Rlimit{Cur: 1 << 30, Max: 1 << 30}
	if err := syscall.Setrlimit(syscall.RLIMIT_DATA, &lim); err != nil {
		fmt.Fprintln(os.Stderr, "ccs-check pages: no memory limit:", err)
		return 2
	}
	c, err := pages.New(args[1], args[2], args[3], args[4], args[5], args[6])
	if err != nil {
		fmt.Fprintln(os.Stderr, "ccs-check pages:", err)
		return 2
	}
	w := bufio.NewWriter(os.Stdout)
	if err := c.Run(args[0], os.Stdin, w); err != nil {
		fmt.Fprintln(os.Stderr, "ccs-check pages:", err)
		return 2
	}
	return 0
}

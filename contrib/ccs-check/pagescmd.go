package main

import (
	"bufio"
	"fmt"
	"os"
	"syscall"

	"ccs-check/pages"
)

func init() { commands["pages"] = pagesCmd }

// pages SITE DESIGNS BODIES LIST VIEWKEY HOSTS ONION FRONTS LIVE < pages (NUL-separated, relative
// to SITE, projects.json too; FRONTS: frontmatter.awk's lines, a file a commit, ":"-separated;
// LIVE: the live site, its projects.json the addresses its proposals have):
// as pages_py, "page<TAB>=ok" for each page that passes (a donation box's QR code
// qr/<its address>.png); else "page<TAB>!reason". Exit 2, nothing printed, if the
// list, the proposals' renderings or a design can't be read (pages_py stopped there too).
func pagesCmd(args []string) int {
	if len(args) != 9 {
		fmt.Fprintln(os.Stderr, "usage: ccs-check pages SITE DESIGNS BODIES LIST VIEWKEY HOSTS ONION FRONTS LIVE < pages")
		return 2
	}
	// 1 GB at most (of memory written, RLIMIT_DATA): matching a page takes memory as it goes
	lim := syscall.Rlimit{Cur: 1 << 30, Max: 1 << 30}
	if err := syscall.Setrlimit(syscall.RLIMIT_DATA, &lim); err != nil {
		fmt.Fprintln(os.Stderr, "ccs-check pages: no memory limit:", err)
		return 2
	}
	c, err := pages.New(args[1], args[2], args[3], args[4], args[5], args[6], args[7], args[8])
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

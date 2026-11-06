package main

import (
	"fmt"
	"io"
	"os"

	"ccs-check/sitedata"
)

func init() { commands["data"] = dataCmd }

// data FILE LIST PROPOSALS HOSTS LIVE PINS OUT: whether site-data.json FILE passes
// (sitedata.Check): exit 0, and OUT the data as it was checked, written again (sitedata.Clean:
// what the site is built from); or 1 and why on stdout. PROPOSALS: a file of the repository's
// proposals (file.md), one a line; HOSTS: where the repository is (host/path, space-separated);
// LIVE: the live site ("": none); PINS: the gate's record of each proposal's address ("file.md
// address" lines; no file: none yet). Exit 2 if the list, the proposals or the pins can't be read,
// or OUT written.
func dataCmd(args []string) int {
	if len(args) != 7 {
		fmt.Fprintln(os.Stderr, "usage: ccs-check data FILE LIST PROPOSALS HOSTS LIVE PINS OUT")
		return 2
	}
	c, err := sitedata.New(args[1], args[2], args[3], args[4], args[5])
	if err != nil {
		fmt.Fprintln(os.Stderr, "ccs-check data:", err)
		return 2
	}
	f, err := os.Open(args[0])
	if err != nil {
		fmt.Println("no site-data.json to read")
		return 1
	}
	defer f.Close()
	b, err := io.ReadAll(io.LimitReader(f, sitedata.Max+1))
	if err != nil {
		fmt.Println("site-data.json can't be read")
		return 1
	}
	out, why := c.Clean(b)
	if why != "" {
		fmt.Println(why)
		return 1
	}
	if err := os.WriteFile(args[6], out, 0o644); err != nil {
		fmt.Fprintln(os.Stderr, "ccs-check data:", err)
		return 2
	}
	return 0
}

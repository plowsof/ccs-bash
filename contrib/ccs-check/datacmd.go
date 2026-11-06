package main

import (
	"fmt"
	"io"
	"os"

	"ccs-check/sitedata"
)

func init() { commands["data"] = dataCmd }

// data FILE LIST PROPOSALS HOSTS LIVE: whether site-data.json FILE passes (sitedata.Check):
// exit 0, or 1 and why on stdout. PROPOSALS: a file of the repository's proposals (file.md), one a
// line; HOSTS: where the repository is (host/path, space-separated); LIVE: the live site ("":
// none). Exit 2 if the list or the proposals can't be read.
func dataCmd(args []string) int {
	if len(args) != 5 {
		fmt.Fprintln(os.Stderr, "usage: ccs-check data FILE LIST PROPOSALS HOSTS LIVE")
		return 2
	}
	c, err := sitedata.New(args[1], args[2], args[3], args[4])
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
	if why := c.Check(b); why != "" {
		fmt.Println(why)
		return 1
	}
	return 0
}

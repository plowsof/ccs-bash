package main

import (
	"fmt"
	"io"
	"os"

	"ccs-check/sitedata"
)

func init() { commands["ideas"] = ideasCmd }

// ideas < IDEAS.json: the backend's ideas (a JSON array), without those whose name or author the
// gate's data check refuses (sitedata.Ideas): with an address in it, or not plain text. Anyone
// can open an MR, so one such title would otherwise hold back every push. Prints the ideas kept;
// each one dropped is told on stderr, by its link. Exits 2 if IDEAS isn't a JSON array.
func ideasCmd(args []string) int {
	if len(args) != 0 {
		fmt.Fprintln(os.Stderr, "usage: ccs-check ideas < IDEAS.json")
		return 2
	}
	b, err := io.ReadAll(io.LimitReader(os.Stdin, sitedata.Max+1))
	if err != nil || len(b) > sitedata.Max {
		fmt.Fprintln(os.Stderr, "ccs-check ideas: can't read the ideas (4 MB at most)")
		return 2
	}
	out, dropped, err := sitedata.Ideas(b)
	if err != nil {
		fmt.Fprintln(os.Stderr, "ccs-check ideas:", err)
		return 2
	}
	for _, d := range dropped {
		fmt.Fprintln(os.Stderr, "dropped:", d)
	}
	os.Stdout.Write(out)
	return 0
}

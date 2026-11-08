package main

import (
	"bufio"
	"fmt"
	"io"
	"os"

	"ccs-check/scan"
)

func init() {
	commands["scan"] = files(scan.Pages)
	commands["json"] = files(scan.JSON)
	commands["nul"] = files(scan.NUL)
}

// files: check FILE... and write the result lines to stdout. Exits 2 if a file can't be read.
func files(check func([]string, io.Writer) error) func([]string) int {
	return func(args []string) int {
		w := bufio.NewWriter(os.Stdout)
		err := check(args, w)
		w.Flush()
		if err != nil {
			fmt.Fprintln(os.Stderr, "ccs-check:", err)
			return 2
		}
		return 0
	}
}

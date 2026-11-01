package main

import (
	"bufio"
	"fmt"
	"io"
	"os"

	"ccs-check/pixels"
	"ccs-check/scan"
)

func init() {
	commands["scan"] = files(scan.Pages)
	commands["json"] = files(scan.JSON)
	commands["nul"] = files(scan.NUL)
	commands["pixels"] = pixelsCmd
}

// files: a check of FILE... writing its lines to stdout; exit 2 if it couldn't read one
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

// pixels < PNG: as pixels_py, "<width> <height> <sha256 of its RGBA pixels>"; nothing (and 1)
// for a PNG qrencode couldn't have written
func pixelsCmd(args []string) int {
	got, err := pixels.Of(os.Stdin)
	if err != nil || len(args) != 0 {
		return 1
	}
	fmt.Println(got)
	return 0
}

package main

import (
	"bytes"
	"fmt"
	"os"

	"ccs-check/scan"
)

func init() { commands["nobidi"] = nobidiCmd }

// nobidi FILE...: each file without its bidi controls (scan.Nobidi), rewritten in place (beside
// it, then renamed over it) only if it had one; their names on stdout. Exit 2 if one can't be
// read or written. The gate's build runs it on the proposals' text before the site is made.
func nobidiCmd(args []string) int {
	for _, f := range args {
		b, err := os.ReadFile(f)
		if err != nil {
			fmt.Fprintln(os.Stderr, "ccs-check nobidi:", err)
			return 2
		}
		out := scan.Nobidi(b)
		if bytes.Equal(out, b) {
			continue
		}
		st, err := os.Stat(f)
		if err == nil {
			err = os.WriteFile(f+".nobidi", out, st.Mode().Perm())
		}
		if err == nil {
			err = os.Rename(f+".nobidi", f)
		}
		if err != nil {
			fmt.Fprintln(os.Stderr, "ccs-check nobidi:", err)
			return 2
		}
		fmt.Println(f)
	}
	return 0
}

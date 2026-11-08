package main

import (
	"fmt"
	"os"
	"strings"

	"ccs-check/gate"
)

func init() { commands["gate"] = gateCmd }

// gate KEY=VALUE...: print the built site's files that may not go live (gate.Run), then
// "checked N files" on stderr. Keys: site, list, allowed. Exits 2 and prints nothing if it
// couldn't decide; then none of the site may go live.
func gateCmd(args []string) int {
	kv := map[string]string{}
	for _, a := range args {
		k, v, ok := strings.Cut(a, "=")
		if !ok {
			fmt.Fprintln(os.Stderr, "usage: ccs-check gate KEY=VALUE...")
			return 2
		}
		kv[k] = v
	}
	c := gate.Config{Site: kv["site"], List: kv["list"], Allowed: kv["allowed"]}
	if c.Site == "" || c.List == "" {
		fmt.Fprintln(os.Stderr, "ccs-check gate: site and list are needed")
		return 2
	}
	n, err := gate.Run(c, os.Stdout)
	if err != nil {
		fmt.Fprintln(os.Stderr, "ccs-check gate:", err)
		return 2
	}
	fmt.Fprintf(os.Stderr, "checked %d files\n", n)
	return 0
}

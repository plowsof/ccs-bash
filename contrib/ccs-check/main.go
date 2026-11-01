// ccs-check: the gate's checks (contrib/ccs-receive) in Go, one static binary in place of its
// Python blocks (docs/python.md). Each subcommand takes the command line of the block it
// replaces and prints the same lines ("file<TAB>ok", "file<TAB>!reason", "file<TAB>address"),
// so ccs-receive changes one line per check. Built by StageX's Go (build.sh, gate.Dockerfile)
// from vendor/ alone: no network, no cgo.
package main

import (
	"fmt"
	"os"
)

// the subcommands, each ported from its Python block (ccs-receive) in turn; one not yet ported
// exits 2, which ccs-receive treats as a check that couldn't run (held back)
var commands = map[string]func(args []string) int{}

func main() {
	if len(os.Args) == 2 && os.Args[1] == "--check" {
		os.Exit(0) // it runs: the gate's image test (tests/gate-image.sh)
	}
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: ccs-check scan|json|nul FILE... | qr KIND IMAGE [inverted] | pixels < PNG | pages SITE DESIGNS BODIES LIST VIEWKEY HOSTS ONION < pages | rrsync DIR (--check: it runs)")
		os.Exit(2)
	}
	run, ok := commands[os.Args[1]]
	if !ok {
		fmt.Fprintf(os.Stderr, "ccs-check: %s: no such check (yet)\n", os.Args[1])
		os.Exit(2)
	}
	os.Exit(run(os.Args[2:]))
}

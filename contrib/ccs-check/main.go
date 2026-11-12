// ccs-check: the gate's checks (contrib/ccs-receive) in Go, as one static binary.
// Each subcommand prints its verdicts as lines ("file<TAB>=ok", "file<TAB>!reason",
// "file<TAB>address"); the gate subcommand combines them (gate/gate.go).
// Built with StageX's Go (build.sh, gate.Dockerfile) from the standard library only: no modules,
// no network, no cgo.
package main

import (
	"fmt"
	"os"
)

// The subcommands. An unknown one exits 2, which the gate treats as a check that couldn't run
// (so everything is held back).
var commands = map[string]func(args []string) int{}

func main() {
	if len(os.Args) == 2 && os.Args[1] == "--check" {
		os.Exit(0) // proves it runs, for the gate's image test (tests/gate-image.sh)
	}
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: ccs-check scan|json|nul|nobidi FILE... | data FILE LIST PROPOSALS HOSTS LIVE PINS OUT | ideas < IDEAS.json | gate KEY=VALUE... | receive DIR < site-data.json | copy [--delete] SRC DST (--check: it runs)")
		os.Exit(2)
	}
	run, ok := commands[os.Args[1]]
	if !ok {
		fmt.Fprintf(os.Stderr, "ccs-check: %s: no such check (yet)\n", os.Args[1])
		os.Exit(2)
	}
	os.Exit(run(os.Args[2:]))
}

package main

import (
	"fmt"
	"os"
	"strings"

	"ccs-check/gate"
)

func init() { commands["gate"] = gateCmd }

// gate KEY=VALUE...: the push's files that don't go live (gate.Run), then "checking N of M" on
// stderr. Keys: staging, live, list, allowed, design (design.sha256), designs, bodies, viewkey,
// hosts, onion, fronts (ccs-check pages'), images ("" if the repository wasn't read), feedawk,
// site, held, full (1: every page and JSON file). Exit 2, nothing printed, if it couldn't decide:
// then nothing of the push may go live.
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
	self, err := os.Executable()
	if err != nil {
		fmt.Fprintln(os.Stderr, "ccs-check gate:", err)
		return 2
	}
	c := gate.Config{Staging: kv["staging"], Live: kv["live"], List: kv["list"], Allowed: kv["allowed"],
		DesignSums: kv["design"], Designs: kv["designs"], Bodies: kv["bodies"], Viewkey: kv["viewkey"],
		Hosts: kv["hosts"], Onion: kv["onion"], Fronts: kv["fronts"], Images: kv["images"],
		FeedAwk: kv["feedawk"], Site: kv["site"], Held: kv["held"], Full: kv["full"] == "1", Self: self}
	if c.Staging == "" || c.Live == "" || c.List == "" || c.DesignSums == "" || c.FeedAwk == "" {
		fmt.Fprintln(os.Stderr, "ccs-check gate: staging, live, list, design and feedawk are needed")
		return 2
	}
	n, total, err := gate.Run(c, os.Stdout)
	if err != nil {
		fmt.Fprintln(os.Stderr, "ccs-check gate:", err)
		return 2
	}
	fmt.Fprintf(os.Stderr, "checking %d of %d\n", n, total)
	return 0
}

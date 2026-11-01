package main

import (
	"fmt"
	"os"
	"syscall"

	"ccs-check/rrsync"
)

func init() { commands["rrsync"] = rrsyncCmd }

// rrsync DIR: in place of rrsync -wo -no-del -munge DIR, the push account's forced command (from
// ccs-receive): SSH_ORIGINAL_COMMAND must be the backend's push, then /usr/bin/rsync receives
// it into DIR (this process becomes it, as rrsync's did); exit 1 and the reason if it isn't
func rrsyncCmd(args []string) int {
	if len(args) != 1 {
		fmt.Fprintln(os.Stderr, "usage: ccs-check rrsync DIR (SSH_ORIGINAL_COMMAND: the push)")
		return 2
	}
	argv, err := rrsync.Args(os.Getenv("SSH_ORIGINAL_COMMAND"))
	if err != nil {
		fmt.Fprintln(os.Stderr, "ccs-check rrsync: refused:", err)
		return 1
	}
	if err := os.Chdir(args[0]); err != nil {
		fmt.Fprintln(os.Stderr, "ccs-check rrsync:", err)
		return 1
	}
	err = syscall.Exec("/usr/bin/rsync", argv, os.Environ())
	fmt.Fprintln(os.Stderr, "ccs-check rrsync: /usr/bin/rsync:", err)
	return 1
}

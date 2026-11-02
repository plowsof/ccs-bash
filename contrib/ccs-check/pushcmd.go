package main

import (
	"bufio"
	"fmt"
	"os"

	"ccs-check/push"
)

func init() {
	commands["receive"] = receiveCmd
	commands["copy"] = copyCmd
}

// receive DIR: the backend's push, a tar on stdin (contrib/ccs-push), written into DIR (the
// gate's staging folder) as push.Receive takes it; exit 1 and the reason if it refuses it
func receiveCmd(args []string) int {
	if len(args) != 1 {
		fmt.Fprintln(os.Stderr, "usage: ccs-check receive DIR < tar")
		return 2
	}
	files, err := push.Receive(bufio.NewReaderSize(os.Stdin, 1<<16), args[0], push.Default)
	if err != nil {
		fmt.Fprintln(os.Stderr, "ccs-check receive: refused:", err)
		return 1
	}
	fmt.Fprintf(os.Stderr, "ccs-check receive: %d files\n", len(files))
	return 0
}

// copy [--delete] SRC DST: DST made to hold SRC's files (push.Copy), in place of rsync -a
// [--delete]: the live site into staging before a push, staging into the live site after
func copyCmd(args []string) int {
	del := len(args) == 3 && args[0] == "--delete"
	if del {
		args = args[1:]
	}
	if len(args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: ccs-check copy [--delete] SRC DST")
		return 2
	}
	if err := push.Copy(args[0], args[1], del); err != nil {
		fmt.Fprintln(os.Stderr, "ccs-check copy:", err)
		return 1
	}
	return 0
}

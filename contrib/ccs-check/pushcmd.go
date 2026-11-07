package main

import (
	"fmt"
	"os"

	"ccs-check/push"
	"ccs-check/sitedata"
)

func init() {
	commands["receive"] = receiveCmd
	commands["copy"] = copyCmd
}

// receive DIR: the backend's push, site-data.json on stdin (contrib/ccs-push), as
// DIR/site-data.json (the gate's staging folder; nothing sent, the heartbeat: no file); exit 1 and
// the reason if it refuses it (push.Data)
func receiveCmd(args []string) int {
	if len(args) != 1 {
		fmt.Fprintln(os.Stderr, "usage: ccs-check receive DIR < site-data.json")
		return 2
	}
	got, err := push.Data(os.Stdin, args[0], sitedata.Max)
	if err != nil {
		fmt.Fprintln(os.Stderr, "ccs-check receive: refused:", err)
		return 1
	}
	if got {
		fmt.Fprintln(os.Stderr, "ccs-check receive: site-data.json")
	}
	return 0
}

// copy [--delete] SRC DST: DST made to hold SRC's files (push.Copy), in place of rsync -a
// [--delete]: staging into the live site after the gate's checks
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

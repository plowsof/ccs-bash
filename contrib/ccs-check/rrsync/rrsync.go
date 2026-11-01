// Package rrsync: the push account's rsync, as rrsync -wo -no-del -munge DIR restricted it, for
// the one command the backend sends (contrib/docker/backend/step: rsync -a [--checksum]
// --delay-updates SITE/ host:), which reaches the server as
//
//	rsync --server -logDtp[r][c]e.<capabilities> --delay-updates . .
//
// and nothing else: no --sender (it only receives), no delete, no other option, no path but
// DIR's own. rrsync filters any client's options (its table of them, in Python); this takes one.
package rrsync

import (
	"errors"
	"regexp"
	"strings"
)

// the short options -a and --checksum send (-l -o -g -D -t -p -r, -c), then -e and the protocol's
// capabilities (incremental recursion, symlink times, safe file lists, varint flags...): each
// letter at most once
var flags = regexp.MustCompile(`^-([logDtprc]+)e\.([iLsfxCIvu]+)$`)

// Args: the receiving rsync's arguments for SSH_ORIGINAL_COMMAND cmd, or why it is refused.
// --munge-links added (an uploaded symlink points nowhere), the files put in the current folder
// (the caller's DIR).
func Args(cmd string) ([]string, error) {
	f := strings.Split(cmd, " ")
	if len(f) != 6 || f[0] != "rsync" || f[1] != "--server" || f[3] != "--delay-updates" || f[4] != "." || f[5] != "." {
		return nil, errors.New("not the push (rsync -a --delay-updates SITE/ host:)")
	}
	m := flags.FindStringSubmatch(f[2])
	if m == nil || twice(m[1]) || twice(m[2]) {
		return nil, errors.New("options other than the push's: " + f[2])
	}
	return []string{"rsync", "--server", f[2], "--delay-updates", "--munge-links", ".", "."}, nil
}

func twice(s string) bool {
	for i, r := range s {
		if strings.ContainsRune(s[i+1:], r) {
			return true
		}
	}
	return false
}

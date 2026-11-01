package rrsync

import (
	"regexp"
	"strings"
	"testing"
)

// only the push's shape is ever allowed, and what runs is it with --munge-links
var push = regexp.MustCompile(`^rsync --server -[logDtprc]+e\.[iLsfxCIvu]+ --delay-updates \. \.$`)

func FuzzArgs(f *testing.F) {
	for _, s := range []string{"rsync --server -logDtpre.iLsfxCIvu --delay-updates . .", "rsync --server --sender -logDtpre.iLsfxCIvu . x", ""} {
		f.Add(s)
	}
	f.Fuzz(func(t *testing.T, cmd string) {
		args, err := Args(cmd)
		if err != nil {
			return
		}
		if !push.MatchString(cmd) {
			t.Fatalf("allowed: %q", cmd)
		}
		if got := strings.Join(args, " "); got != strings.Replace(cmd, " . .", " --munge-links . .", 1) {
			t.Fatalf("%q runs %q", cmd, got)
		}
	})
}

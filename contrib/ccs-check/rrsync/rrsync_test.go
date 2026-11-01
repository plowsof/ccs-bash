package rrsync

import (
	"strings"
	"testing"
)

func TestPush(t *testing.T) {
	// rsync 3.2.7 and 3.5.0 (the backend's), with --checksum and without
	for _, f := range []string{"-logDtprce.iLsfxCIvu", "-logDtpre.iLsfxCIvu"} {
		got, err := Args("rsync --server " + f + " --delay-updates . .")
		want := "rsync --server " + f + " --delay-updates --munge-links . ."
		if err != nil || strings.Join(got, " ") != want {
			t.Errorf("%s: %q %v", f, got, err)
		}
	}
}

func TestRefused(t *testing.T) {
	for _, cmd := range []string{
		"",
		"id",
		"rsync --server --sender -logDtpre.iLsfxCIvu . proposals.json", // reading back
		"rsync --server -logDtpre.iLsfxCIvu --delay-updates . ../escaped",
		"rsync --server -logDtpre.iLsfxCIvu --delay-updates . /tmp/escaped",
		"rsync --server -logDtpre.iLsfxCIvu --delay-updates --delete . .",
		"rsync --server -logDtpre.iLsfxCIvu --delay-updates --temp-dir=/tmp/escaped . .",
		"rsync --server -logDtpre.iLsfxCIvu --log-file=/tmp/x . .",
		"rsync --server -logDtpbre.iLsfxCIvu --delay-updates . .", // -b, backups
		"rsync --server -logDtpRe.iLsfxCIvu --delay-updates . .",  // -R
		"rsync --server -llogDtpre.iLsfxCIvu --delay-updates . .", // a letter twice
		"rsync --server -logDtpre.iLsfxCIvuZ --delay-updates . .", // a capability not known
		"rsync --server -logDtpr --delay-updates . .",
		"rsync  --server -logDtpre.iLsfxCIvu --delay-updates . .", // two spaces
		"rsync --server -logDtpre.iLsfxCIvu --delay-updates . .\n",
		"rsync --server\t-logDtpre.iLsfxCIvu --delay-updates . .",
		"/usr/bin/rsync --server -logDtpre.iLsfxCIvu --delay-updates . .",
	} {
		if got, err := Args(cmd); err == nil {
			t.Errorf("%q: allowed: %q", cmd, got)
		}
	}
}

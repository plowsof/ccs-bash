package sitedata

import "testing"

// Any input gets an answer, never a panic
func FuzzCheck(f *testing.F) {
	f.Add(good)
	f.Add(`{"state":{},"funds":{},"ideas":[]}`)
	c := setup(f)
	f.Fuzz(func(t *testing.T, s string) { c.Check([]byte(s)) })
}

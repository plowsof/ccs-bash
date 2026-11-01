module ccs-check

go 1.27

require (
	github.com/makiuchi-d/gozxing v0.1.2-0.20250720151325-95e256b768ac
	golang.org/x/xerrors v0.0.0-20200804184101-5ec99f83aff1
)

// Both from their pinned archives (container/sources.lock), unpacked by deps.sh into ../deps
// (build.sh, gate.Dockerfile): go fetches nothing.
replace (
	github.com/makiuchi-d/gozxing => ../deps/gozxing
	golang.org/x/xerrors => ../deps/xerrors
)

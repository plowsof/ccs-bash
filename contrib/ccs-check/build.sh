#!/usr/bin/env bash
# build.sh OUT: build ccs-check into OUT with StageX's Go (container/images' pin, signatures
# checked), as gate.Dockerfile builds it: its modules from their pinned archives
# (container/sources.lock, fetched by container/fetch.sh, unpacked by deps.sh), no network in
# the build, so the same bytes as the gate image's /usr/local/bin/ccs-check (a host setup checks
# its sha256 against the release's). build.sh test: gofmt, go vet and the Go tests, the same
# way. build.sh fuzz [SECONDS]: each fuzz test (*/fuzz_test.go) for SECONDS (30), no network; an
# input that fails it is kept in its package's testdata/fuzz/ (commit it: go test runs it
# after). build.sh vulncheck: govulncheck (pinned below, checked against Go's checksum database)
# on this code as built, Go's standard library and its modules: the known vulnerabilities in
# what it calls (Go's database, so a network). Needs docker, and the network once for the
# archives.
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
repo=$(dirname "$(dirname "$here")")
ref=$(awk '$1 == "go" { print $2 }' "$repo/container/images")
[[ $ref ]] || { echo "error: no go in container/images" >&2; exit 1; }
"$repo/container/verify-images.sh" <(grep -E '^go ' "$repo/container/images") 2> /dev/null \
    || { echo "error: StageX's Go ($ref) isn't signed as container/images needs" >&2; exit 1; }
docker pull -q "$ref" > /dev/null
# the modules, at ../deps as go.mod has them (each archive checked by its sha256)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
"$repo/container/fetch.sh" "$repo/container/sources" 2> /dev/null \
    || { echo "error: the pinned archives (container/sources.lock) could not be fetched" >&2; exit 1; }
"$here/deps.sh" "$repo/container/sources" "$tmp/deps"
network=(--network none) src=:ro
# go TOOL [DOCKER OPTION...] -- ARG...: StageX's TOOL (go, gofmt; or a path) on a read-only copy
# of this folder and the modules, as the build stage runs it (/tmp exec: go test runs its
# binaries there)
go() {
    local tool=$1 opts=()
    shift
    while [[ $1 != -- ]]; do opts+=("$1"); shift; done
    shift
    docker run --rm "${network[@]}" --read-only --tmpfs /tmp:exec -u "$(id -u):$(id -g)" \
        -v "$here:/src$src" -v "$tmp/deps:/deps:ro" -w /src -e HOME=/tmp -e GOCACHE=/tmp/cache -e GOPATH=/tmp/go \
        -e CGO_ENABLED=0 -e GOFLAGS=-mod=readonly -e GOPROXY=off -e GOTOOLCHAIN=local \
        "${opts[@]}" --entrypoint "$([[ $tool == /* ]] && echo "$tool" || echo "/usr/bin/$tool")" "$ref" "$@"
}
# govulncheck: Go's vulnerability scanner, by version (its module's checksum from Go's database)
govulncheck=golang.org/x/vuln/cmd/govulncheck@v1.9.0
if [[ ${1:-} == vulncheck ]]; then
    mkdir "$tmp/bin"
    network=(--network bridge)
    net=(-v /etc/ssl/certs:/etc/ssl/certs:ro -v "$tmp/bin:/gobin" -e GOBIN=/gobin)
    go go "${net[@]}" -e GOFLAGS=-mod=mod -e GOPROXY=https://proxy.golang.org -e GOSUMDB=sum.golang.org -- install "$govulncheck"
    go /gobin/govulncheck "${net[@]}" -- "${@:2}" ./...
    exit
fi
if [[ ${1:-} == fuzz ]]; then
    src=''   # (writable: go test keeps a failing input in testdata/fuzz/)
    for f in "$here"/*/fuzz_test.go; do
        pkg=$(basename "$(dirname "$f")")
        while read -r name; do
            echo "fuzz: $pkg $name, ${2:-30} s" >&2
            go go -- test -run='^$' -fuzz="^$name\$" -fuzztime="${2:-30}s" "./$pkg" < /dev/null || exit 1
        done < <(sed -n 's/^func \(Fuzz[A-Za-z0-9]*\)(.*/\1/p' "$f")
    done
    exit
fi
if [[ ${1:-} == test ]]; then
    bad=$(go gofmt -- -l .) || exit 1
    [[ -z $bad ]] || { echo "error: not gofmt'd: $bad" >&2; exit 1; }
    go go -- vet ./... && go go -- test ./...
    exit
fi
mkdir -p "$(dirname "${1:?usage: build.sh OUT | test | fuzz [SECONDS] | vulncheck}")"
out=$(readlink -f "$1")
go go -v "$(dirname "$out"):/out" -- \
    build -trimpath -buildvcs=false -ldflags=-buildid= -o "/out/$(basename "$out")" .
sha256sum "$out"

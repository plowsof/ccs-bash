#!/usr/bin/env bash
# deps.sh SOURCES OUT: ccs-check's two modules, from their pinned archives in SOURCES
# (container/sources.lock; each the same files as Go's checksum database has for its version),
# into OUT/gozxing and OUT/xerrors (go.mod: replace ../deps/...): of gozxing only its QR
# reader's files (deps/gozxing.files: no encoder, no other kind of code), with
# deps/gozxing.patch (no golang.org/x/text: a code's bytes read as ISO-8859-1); of x/xerrors,
# its files but its tests. Runs in gate.Dockerfile (busybox) and build.sh: no GNU-only options.
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
src=$1 out=$2
# h1 DIR MODULE@VERSION: Go's dirhash h1 (go.sum's, the checksum database's) of the module's files
# in DIR: each file's sha256 and "MODULE@VERSION/path", sorted, hashed again, in base64. Files under
# a folder with a go.mod of its own (another module) aren't the module's.
h1() {
    local f d sub hex
    hex=$(cd "$1" && find . -type f | sed 's#^\./##' | LC_ALL=C sort | while IFS= read -r f; do
        d=$(dirname "$f") sub=0
        while [[ $d != . ]]; do [[ -f $d/go.mod ]] && sub=1; d=$(dirname "$d"); done
        ((sub)) || printf '%s  %s\n' "$(sha256sum < "$f" | cut -d' ' -f1)" "$2/$f"
    done | sha256sum | cut -d' ' -f1)
    local i b=''
    for ((i = 0; i < ${#hex}; i += 2)); do b+="\\x${hex:i:2}"; done
    printf '%b' "$b" | base64
}
# unpack TARBALL TOP MODULE@VERSION H1 LIST DEST: the archive's files (its folder TOP) checked to be
# the module version's, as Go's checksum database has it (H1), then LIST's of them into DEST
unpack() {
    local tmp got
    tmp=$(mktemp -d)
    tar -xzf "$1" -C "$tmp"
    got=$(h1 "$tmp/$2" "$3")
    if [ "h1:$got" != "$4" ]; then
        echo "error: $1 isn't $3 as Go's checksum database has it (h1:$got, not $4)" >&2
        exit 1
    fi
    mkdir -p "$6"
    # shellcheck disable=SC2046 # (one word a file: the lists have no spaces)
    (cd "$tmp/$2" && tar -cf - $(cat "$5")) | tar -xf - -C "$6"
    rm -rf "$tmp"
}
unpack "$src/95e256b768ac998970103689922aaf7e8c5cae34.tar.gz" gozxing-95e256b768ac998970103689922aaf7e8c5cae34 \
    github.com/makiuchi-d/gozxing@v0.1.2-0.20250720151325-95e256b768ac h1:Iwm/nSTFNZTKb2hVNoXL3og/8hjxSsSYIz885k+2pFs= \
    "$here/deps/gozxing.files" "$out/gozxing"
(cd "$out/gozxing" && patch -p1 < "$here/deps/gozxing.patch" > /dev/null)
unpack "$src/5ec99f83aff198f5fbd629d6c8d8eb38a04218ca.tar.gz" xerrors-5ec99f83aff198f5fbd629d6c8d8eb38a04218ca \
    golang.org/x/xerrors@v0.0.0-20200804184101-5ec99f83aff1 h1:go1bK/D/BFZV2I8cIQd1NKEZ+0owSTG1fDTci4IqFcE= \
    "$here/deps/xerrors.files" "$out/xerrors"

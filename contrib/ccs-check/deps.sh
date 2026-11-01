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
# unpack TARBALL TOP LIST DEST: LIST's files of the archive (its folder TOP), into DEST
unpack() {
    local tmp
    tmp=$(mktemp -d)
    # shellcheck disable=SC2046 # (one word a file: the lists have no spaces)
    tar -xzf "$1" -C "$tmp" $(sed "s#^#$2/#" "$3")
    mkdir -p "$4"
    cp -R "$tmp/$2/." "$4/"
    rm -rf "$tmp"
}
unpack "$src/95e256b768ac998970103689922aaf7e8c5cae34.tar.gz" gozxing-95e256b768ac998970103689922aaf7e8c5cae34 \
    "$here/deps/gozxing.files" "$out/gozxing"
(cd "$out/gozxing" && patch -p1 < "$here/deps/gozxing.patch" > /dev/null)
unpack "$src/5ec99f83aff198f5fbd629d6c8d8eb38a04218ca.tar.gz" xerrors-5ec99f83aff198f5fbd629d6c8d8eb38a04218ca \
    "$here/deps/xerrors.files" "$out/xerrors"

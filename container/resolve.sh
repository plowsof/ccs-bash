#!/usr/bin/env bash
# resolve.sh SNAPSHOT PACKAGE...: runs inside a throwaway copy of the pinned base image
# (see update-lock.sh). Prints "sha256 size url" for every .deb those packages need on
# top of the image, from snapshot.debian.org at SNAPSHOT.
#
# apt downloads each file once, checking it against Debian's signed index; its sum is
# taken from that download, since apt's --print-uris alone only gives MD5.
set -euo pipefail
snapshot=$1
shift

rm -f /etc/apt/sources.list.d/*
cat > /etc/apt/sources.list <<SOURCES
deb http://snapshot.debian.org/archive/debian/$snapshot bookworm main
deb http://snapshot.debian.org/archive/debian/$snapshot bookworm-updates main
deb http://snapshot.debian.org/archive/debian-security/$snapshot bookworm-security main
SOURCES
apt-get -qq -o Acquire::Check-Valid-Until=false update
apt-get -qq --no-install-recommends --print-uris install "$@" > /tmp/uris
apt-get -qq --no-install-recommends --download-only install "$@" > /dev/null

cd /var/cache/apt/archives
# each line: 'URL' FILE SIZE MD5Sum:...
while read -r url file size _; do
    url=${url//\'/}
    printf '%s %s %s\n' "$(sha256sum "$file" | cut -d' ' -f1)" "$size" "${url/#http:/https:}"
done < /tmp/uris

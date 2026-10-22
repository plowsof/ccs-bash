#!/usr/bin/env bash
# check-pinned.sh: check the image hash is pinned. Builds the image twice from scratch, from
# two separate clones of the current commit (different paths, umasks and times), and fails
# unless both give the same image hash. Anyone can do the same to check an image they were given.
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
repo=$(git -C "$here" rev-parse --show-toplevel)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"; docker image rm -f ccs-bash:repro1 ccs-bash:repro2 > /dev/null 2>&1 || true' EXIT

"$here/fetch.sh" "$tmp/sources"                # once; both builds get the same checked files
declare -A id
for i in 1 2; do
    (umask "$([[ $i == 1 ]] && echo 022 || echo 077)" && git clone -q "$repo" "$tmp/clone$i")
    cp -r "$tmp/sources" "$tmp/clone$i/container/sources"
    NO_CACHE=1 "$tmp/clone$i/container/build.sh" "ccs-bash:repro$i" > /dev/null 2>&1
    id[$i]=$(docker image inspect "ccs-bash:repro$i" --format '{{.Id}}')
    echo "build $i: ${id[$i]}"
    sleep 2
done
if [[ ${id[1]} != "${id[2]}" ]]; then
    echo "error: the image hash is not pinned, the two builds differ" >&2
    exit 1
fi
echo "pinned: commit $(git -C "$repo" rev-parse --short HEAD) builds to ${id[1]}"

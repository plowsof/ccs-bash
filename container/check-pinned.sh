#!/usr/bin/env bash
# check-pinned.sh: fail unless two clean builds of this commit from separate clones (other
# paths, umasks, times) and one on a cache left by another commit all give the same hash.
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
repo=$(git -C "$here" rev-parse --show-toplevel)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"; docker image rm -f ccs-bash:other ccs-bash:warm ccs-bash:repro1 ccs-bash:repro2 > /dev/null 2>&1 || true' EXIT

"$here/fetch.sh" "$tmp/sources"                # once; every build gets the same checked files
declare -A id
for c in other warm; do
    git clone -q "$repo" "$tmp/$c"
    cp -r "$tmp/sources" "$tmp/$c/container/sources"
done
GIT_COMMITTER_DATE="@$(($(git -C "$repo" log -1 --format=%ct) - 86400)) +0000" \
    git -C "$tmp/other" -c user.name=check -c user.email=check@invalid commit -q --allow-empty -m other
"$tmp/other/container/build.sh" ccs-bash:other > /dev/null 2>&1
"$tmp/warm/container/build.sh" ccs-bash:warm > /dev/null 2>&1
id[warm]=$(docker image inspect ccs-bash:warm --format '{{.Id}}')
echo "build with a cache from another commit: ${id[warm]}"
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
if [[ ${id[warm]} != "${id[1]}" ]]; then
    echo "error: a build cache from another commit changes the image hash" >&2
    exit 1
fi
echo "pinned: commit $(git -C "$repo" rev-parse --short HEAD) builds to ${id[1]}"

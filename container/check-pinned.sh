#!/usr/bin/env bash
# check-pinned.sh: fail unless two clean builds of this commit from separate clones (other
# paths, umasks, times) and one on a cache left by another commit all give the same hash.
# One of those builds alone, printing "id: <image id>": check-pinned.sh clean UMASK | warm (CI
# runs warm, under umask 077, on a second machine and compares it with its clean build).
# CHECK_DOCKERFILE=gate.Dockerfile: the gate's image instead (contrib/docker/web).
set -euo pipefail
shopt -s inherit_errexit   # (a failed build stops clean and warm, run in $(...))
here=$(dirname "$(readlink -f "$0")")
repo=$(git -C "$here" rev-parse --show-toplevel)
name=$(basename "$repo") dockerfile=${CHECK_DOCKERFILE:-Dockerfile}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"; docker image rm -f "$name:other" "$name:warm" "$name:repro1" "$name:repro2" > /dev/null 2>&1 || true' EXIT

# once; every build gets the same checked files (those already in container/sources, a cache's,
# kept when their sha256 matches)
mkdir -p "$tmp/sources"
if [[ -d $here/sources ]]; then cp -r "$here/sources/." "$tmp/sources/"; fi
"$here/fetch.sh" "$tmp/sources"

# clean N UMASK: a build with no cache, from a fresh clone made under UMASK; prints its image ID
# build DIR TAG: DIR's container/build.sh as TAG, its output kept: shown (its end) if it fails,
# which fails the check
build() {
    if ! "$1/container/build.sh" "$2" "$dockerfile" > "$tmp/build.log" 2>&1; then
        echo "error: the build of $2 failed; its last lines:" >&2
        tail -n 40 "$tmp/build.log" >&2
        return 1
    fi
}

clean() {
    (umask "$2" && git clone -q "$repo" "$tmp/clone$1")
    cp -r "$tmp/sources" "$tmp/clone$1/container/sources"
    NO_CACHE=1 build "$tmp/clone$1" "$name:repro$1"
    docker image inspect "$name:repro$1" --format '{{.Id}}'
}
# warm: a build of another commit (a day older), then this one on the cache it left; prints its ID
warm() {
    local c
    for c in other warm; do
        git clone -q "$repo" "$tmp/$c"
        cp -r "$tmp/sources" "$tmp/$c/container/sources"
    done
    GIT_COMMITTER_DATE="@$(($(git -C "$repo" log -1 --format=%ct) - 86400)) +0000" \
        git -C "$tmp/other" -c user.name=check -c user.email=check@invalid commit -q --allow-empty -m other
    build "$tmp/other" "$name:other"
    build "$tmp/warm" "$name:warm"
    docker image inspect "$name:warm" --format '{{.Id}}'
}

case ${1:-} in
    # (an assignment: a failed build fails the script, as an echo of it wouldn't)
    clean) i=$(clean 1 "${2:?UMASK}"); echo "id: $i"; exit ;;
    warm) i=$(warm); echo "id: $i"; exit ;;
    "") ;;
    *) echo "usage: check-pinned.sh [clean UMASK | warm]" >&2; exit 1 ;;
esac

declare -A id
id[warm]=$(warm)
echo "build with a cache from another commit: ${id[warm]}"
for i in 1 2; do
    id[$i]=$(clean "$i" "$([[ $i == 1 ]] && echo 022 || echo 077)")
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

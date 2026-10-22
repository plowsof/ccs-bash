#!/usr/bin/env bash
# build.sh [TAG]: build the ccs-bash image from pinned StageX images, in two steps.
#   1. download (network): every image in images, by digest, and the sources in sources.lock
#   2. build (no network): docker buildx build --network none, from exactly those
# NO_CACHE=1 rebuilds every step.
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
tag=${1:-ccs-bash}

contexts=()
while read -r name ref; do
    docker pull -q "$ref" > /dev/null
    contexts+=(--build-context "$name=docker-image://$ref")
done < <(grep -v '^#' "$here/images")
"$here/fetch.sh" "$here/sources"

# Same commit, same image hash: every time in the image is the commit's time. The last two
# steps (fix, image) are never taken from the cache: BuildKit leaves SOURCE_DATE_EPOCH out of
# its cache keys and compares copied files by content only, so a cached result from another
# commit would come back with that commit's file times (and another image hash).
epoch=$(git -C "$here" log -1 --format=%ct)
cache=(--no-cache-filter fix --no-cache-filter image)
[[ ${NO_CACHE:-} ]] && cache=(--no-cache)   # buildx refuses both together
docker buildx build "${cache[@]}" --network none --pull=false "${contexts[@]}" \
    --build-arg SOURCE_DATE_EPOCH="$epoch" \
    --output type=docker,name="$tag",rewrite-timestamp=true -f "$here/Dockerfile" "$here/.."
docker image inspect "$tag" --format "$tag {{.Id}}" >&2

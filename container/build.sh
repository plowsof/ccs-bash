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

# Same commit, same image hash: every time in the image is the commit's time.
epoch=$(git -C "$here" log -1 --format=%ct)
docker buildx build ${NO_CACHE:+--no-cache} --network none --pull=false "${contexts[@]}" \
    --build-arg SOURCE_DATE_EPOCH="$epoch" \
    --output type=docker,name="$tag",rewrite-timestamp=true -f "$here/Dockerfile" "$here/.."
docker image inspect "$tag" --format "$tag {{.Id}}" >&2

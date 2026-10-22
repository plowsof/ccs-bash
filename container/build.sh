#!/usr/bin/env bash
# build.sh [TAG]: build the ccs-bash image in two steps. NO_CACHE=1 rebuilds every step.
#   1. download (network): the base image, by digest, and the .deb files in deps.lock (fetch.sh)
#   2. install (no network): docker build --network none, from exactly those files
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
tag=${1:-ccs-bash}
base=$(cat "$here/base-image")

docker pull -q "$base" > /dev/null
"$here/fetch.sh" "$here/debs"
# Same commit, same image hash: every time in the image is the commit's time.
epoch=$(git -C "$here" log -1 --format=%ct)
docker buildx build ${NO_CACHE:+--no-cache} --network none --pull=false --build-arg BASE="$base" --build-arg SOURCE_DATE_EPOCH="$epoch" \
    --output type=docker,name="$tag",rewrite-timestamp=true -f "$here/Dockerfile" "$here/.."
docker image inspect "$tag" --format "$tag {{.Id}}" >&2

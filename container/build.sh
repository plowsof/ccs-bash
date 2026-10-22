#!/usr/bin/env bash
# build.sh [TAG]: check the pins' signatures, download them and the sources, make StageX's
# BuildKit a builder, build with no network in the steps. NO_CACHE=1 rebuilds everything.
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
tag=${1:-ccs-bash}

"$here/verify-images.sh"
contexts=()
while read -r name ref; do
    docker pull -q "$ref" > /dev/null
    contexts+=(--build-context "$name=docker-image://$ref")
done < <(grep -v '^#' "$here/images")
"$here/fetch.sh" "$here/sources"

# Only copies, so the host's BuildKit makes it; named by its ID, so new pins get a new builder.
docker buildx build -q --builder default --network none --pull=false "${contexts[@]}" \
    --build-arg SOURCE_DATE_EPOCH=0 --output type=docker,name=ccs-bash-builder,rewrite-timestamp=true \
    -f "$here/builder.Dockerfile" "$here" > /dev/null
builder_id=$(docker image inspect ccs-bash-builder --format '{{.Id}}')
builder=ccs-bash-builder-${builder_id:7:12}
docker tag ccs-bash-builder "$builder"
docker buildx inspect "$builder" > /dev/null 2>&1 \
    || docker buildx create --name "$builder" --driver docker-container --driver-opt image="$builder" > /dev/null

# Every time in the image is the commit's. fix and image never come from the cache: its keys
# ignore SOURCE_DATE_EPOCH and file times, so another commit's result would bring its times.
epoch=$(git -C "$here" log -1 --format=%ct)
cache=(--no-cache-filter fix --no-cache-filter image)
[[ ${NO_CACHE:-} ]] && cache=(--no-cache)   # buildx refuses both together
docker buildx build --builder "$builder" "${cache[@]}" --network none "${contexts[@]}" \
    --build-arg SOURCE_DATE_EPOCH="$epoch" \
    --output type=docker,name="$tag",rewrite-timestamp=true -f "$here/Dockerfile" "$here/.."
docker image inspect "$tag" --format "$tag {{.Id}}" >&2

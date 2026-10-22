#!/usr/bin/env bash
# build.sh [TAG]: build the ccs-bash image from pinned StageX images:
#   1. check (network): every image in images is signed by StageX maintainers (verify-images.sh)
#   2. download (network): those images, by digest, and the sources in sources.lock
#   3. the builder: StageX's BuildKit as a buildx builder of its own (builder.Dockerfile)
#   4. build (RUN steps without network): docker buildx build --network none with that builder
# NO_CACHE=1 rebuilds every step.
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

# The builder image only copies, so the host's own BuildKit makes it; named by its image ID,
# so other pins get another builder. Each builder keeps its own cache (docker buildx ls).
docker buildx build -q --builder default --network none --pull=false "${contexts[@]}" \
    --build-arg SOURCE_DATE_EPOCH=0 --output type=docker,name=ccs-bash-builder,rewrite-timestamp=true \
    -f "$here/builder.Dockerfile" "$here" > /dev/null
builder_id=$(docker image inspect ccs-bash-builder --format '{{.Id}}')
builder=ccs-bash-builder-${builder_id:7:12}
docker tag ccs-bash-builder "$builder"
docker buildx inspect "$builder" > /dev/null 2>&1 \
    || docker buildx create --name "$builder" --driver docker-container --driver-opt image="$builder" > /dev/null

# Same commit, same image hash: every time in the image is the commit's time. The last two
# steps (fix, image) are never taken from the cache: BuildKit leaves SOURCE_DATE_EPOCH out of
# its cache keys and compares copied files by content only, so a cached result from another
# commit would come back with that commit's file times (and another image hash).
epoch=$(git -C "$here" log -1 --format=%ct)
cache=(--no-cache-filter fix --no-cache-filter image)
[[ ${NO_CACHE:-} ]] && cache=(--no-cache)   # buildx refuses both together
docker buildx build --builder "$builder" "${cache[@]}" --network none "${contexts[@]}" \
    --build-arg SOURCE_DATE_EPOCH="$epoch" \
    --output type=docker,name="$tag",rewrite-timestamp=true -f "$here/Dockerfile" "$here/.."
docker image inspect "$tag" --format "$tag {{.Id}}" >&2

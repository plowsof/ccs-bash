#!/usr/bin/env bash
# build.sh [TAG]: check the pins' signatures, download them and the sources, make StageX's
# BuildKit a builder, build with no network in the steps. NO_CACHE=1 rebuilds everything.
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
tag=${1:-ccs-bash} dockerfile=${2:-Dockerfile}   # gate.Dockerfile: the gate's image (contrib/docker/web)

# Image IDs, as the releases and ccs-sigs name them, are the image config's digest: Docker's own
# image store. Its containerd store (a fresh Docker 29's default) shows and runs images by their
# manifest's digest instead, an ID no attestation names.
if docker info --format '{{json .DriverStatus}}' | grep -q 'io\.containerd\.snapshotter'; then
    echo 'error: Docker keeps images in its containerd store, where an image ID is not the attested one:' \
        'add "features": {"containerd-snapshotter": false} to /etc/docker/daemon.json, restart Docker, build again' >&2
    exit 1
fi
"$here/verify-images.sh"
contexts=()
while read -r name ref; do
    docker pull -q "$ref" > /dev/null
    contexts+=(--build-context "$name=docker-image://$ref")
done < <(grep -v '^#' "$here/images")
"$here/fetch.sh" "$here/sources"

# Only copies, so the host's BuildKit makes it; named by its ID, so new pins get a new builder
# and the same pins share one, across ccs-bash, ccs-front-bash and ccs-front-hugo (one copy of
# the downloads and the cache, not three).
docker buildx build -q --builder default --network none --pull=false "${contexts[@]}" \
    --build-arg SOURCE_DATE_EPOCH=0 --output type=docker,name=stagex-buildkit,rewrite-timestamp=true \
    -f "$here/builder.Dockerfile" "$here" > /dev/null
builder_id=$(docker image inspect stagex-buildkit --format '{{.Id}}')
builder=stagex-buildkit-${builder_id:7:12}
docker tag stagex-buildkit "$builder"
docker buildx inspect "$builder" > /dev/null 2>&1 \
    || docker buildx create --name "$builder" --driver docker-container --driver-opt image="$builder" > /dev/null

# Every time in the image is the commit's. fix and image never come from the cache: its keys
# ignore SOURCE_DATE_EPOCH and file times, so another commit's result would bring its times.
epoch=$(git -C "$here" log -1 --format=%ct)
cache=(--no-cache-filter fix --no-cache-filter image)
[[ ${NO_CACHE:-} ]] && cache=(--no-cache)   # buildx refuses both together
docker buildx build --builder "$builder" "${cache[@]}" --network none "${contexts[@]}" \
    --build-arg SOURCE_DATE_EPOCH="$epoch" \
    --output type=docker,name="$tag",rewrite-timestamp=true -f "$here/$dockerfile" "$here/.."
docker image inspect "$tag" --format "$tag {{.Id}}" >&2

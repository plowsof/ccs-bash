#!/usr/bin/env bash
# build.sh [TAG]: build the ccs-bash image in two steps.
#   1. download (network): the base image, by digest, and the .deb files in deps.lock (fetch.sh)
#   2. install (no network): docker build --network none, from exactly those files
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
tag=${1:-ccs-bash}
base=$(cat "$here/base-image")

docker pull -q "$base" > /dev/null
"$here/fetch.sh" "$here/debs"
docker build --network none --pull=false --build-arg BASE="$base" -f "$here/Dockerfile" -t "$tag" "$here/.."

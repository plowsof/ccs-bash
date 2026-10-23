#!/usr/bin/env bash
# update-images.sh: pin every image in images to the digest StageX's "latest" tag has now.
# Checks the new pins' signatures (verify-images.sh); review the diff before committing it.
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
while read -r line; do
    if [[ $line == \#* || -z $line ]]; then
        printf '%s\n' "$line"
        continue
    fi
    read -r name ref <<<"$line"
    image=${ref%@*}
    docker pull -q "$image:latest" > /dev/null
    printf '%-26s %s\n' "$name" "$(docker image inspect "$image:latest" --format '{{index .RepoDigests 0}}')"
done < "$here/images" > "$here/images.new"
mv "$here/images.new" "$here/images"
git -C "$here" diff --stat -- images >&2
"$here/update-sigs.sh"
"$here/verify-images.sh"

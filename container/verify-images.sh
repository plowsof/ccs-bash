#!/usr/bin/env bash
# verify-images.sh [IMAGES]: every pinned StageX image (default: images) must be signed by
# two or more maintainers whose keys are in stagex-keys.asc. A pin is an index digest; the
# signatures (sigs.stagex.tools) are on its linux/<arch> manifest. Needs gpg and jq.
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
list=${1:-$here/images}
quorum=2
lookaside=https://sigs.stagex.tools
arch=$(docker version --format '{{.Server.Arch}}')

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export GNUPGHOME=$tmp/gnupg
install -d -m 700 "$GNUPGHOME"
gpg -q --batch --import "$here/stagex-keys.asc"
# only the primary keys listed at the top of stagex-keys.asc count
awk '/^#   [0-9A-F]{40} / { print $2 }' "$here/stagex-keys.asc" > "$tmp/trusted"

failed=0
while read -r name ref; do
    repo=${ref%@*} index=${ref#*@}
    docker buildx imagetools inspect --raw "$ref" > "$tmp/index"
    [[ sha256:$(sha256sum < "$tmp/index" | cut -d' ' -f1) == "$index" ]] \
        || { echo "error: $name: the registry gave an index that is not $index" >&2; exit 1; }
    manifest=$(jq -r --arg arch "$arch" \
        '[.manifests[] | select(.platform.os == "linux" and .platform.architecture == $arch)] | if length == 1 then .[0].digest else empty end' "$tmp/index")
    [[ $manifest =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "error: $name: no single linux/$arch manifest in $index" >&2; exit 1; }

    signers=() others=()
    for n in $(seq 1 20); do
        sig=$tmp/sig
        code=$(curl -sS --max-time 60 -o "$sig" -w '%{http_code}' "$lookaside/$repo@${manifest/:/=}/signature-$n")
        [[ $code == 404 ]] && break
        [[ $code == 200 ]] || { echo "error: $name: signature-$n: HTTP $code from $lookaside" >&2; exit 1; }
        rm -f "$tmp/payload"
        gpg --batch --status-file "$tmp/status" --output "$tmp/payload" --decrypt "$sig" 2> /dev/null || true
        # good, by a trusted key, naming this repo and manifest
        signer=$(awk '$2 == "VALIDSIG" { print $12 }' "$tmp/status")
        if grep -q '^\[GNUPG:\] GOODSIG ' "$tmp/status" && [[ $signer ]] && grep -qx "$signer" "$tmp/trusted" \
            && jq -e --arg repo "$repo" --arg digest "$manifest" '
                .critical.type == "atomic container signature"
                and .critical.image."docker-manifest-digest" == $digest
                and (.critical.identity."docker-reference" | sub("^docker\\.io/"; "") | sub("[:@].*"; "")) == $repo
            ' "$tmp/payload" > /dev/null 2>&1; then
            [[ " ${signers[*]} " == *" $signer "* ]] || signers+=("$signer")
        else
            others+=("signature-$n")   # unknown key (say a former maintainer's) or bad
        fi
    done
    if (( ${#signers[@]} >= quorum )); then
        echo "$name: ${#signers[@]} maintainers signed $manifest" >&2
    else
        echo "error: $name: ${#signers[@]} of $quorum maintainer signatures on $manifest${others:+ (not counted: ${others[*]})}" >&2
        failed=1
    fi
done < <(grep -v '^#' "$list")
(( failed == 0 )) || exit 1
echo "every image in $(basename "$list") is signed by $quorum or more StageX maintainers" >&2

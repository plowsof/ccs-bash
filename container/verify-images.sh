#!/usr/bin/env bash
# verify-images.sh [IMAGES]: every pinned StageX image (default: images) must be signed by
# two or more maintainers whose keys are in stagex-keys.asc. A pin is an index digest; the
# signatures are on its linux/<arch> manifest. They are read from sigs/ (update-sigs.sh copies
# them from sigs.stagex.tools when the pins change), so a build needs nothing from that site;
# only a manifest with none stored there is looked up online. Needs gpg and jq.
set -euo pipefail
quorum=2
lookaside=https://sigs.stagex.tools

# signature_signer FILE REPO MANIFEST: print the primary key fingerprint of FILE if it holds
# exactly one good signature, by a key in $tmp/trusted, naming REPO and MANIFEST; else nothing.
# Exactly one: a file can hold the same maintainer's signature twice, which must not count twice.
signature_signer() {
    local status=$tmp/status payload=$tmp/payload signer
    rm -f "$payload"
    gpg --batch --status-file "$status" --output "$payload" --decrypt "$1" 2> /dev/null || return 0
    [[ $(grep -c '^\[GNUPG:\] NEWSIG' "$status") == 1 && $(grep -c '^\[GNUPG:\] GOODSIG ' "$status") == 1 \
        && $(grep -c '^\[GNUPG:\] VALIDSIG ' "$status") == 1 ]] || return 0
    signer=$(awk '$2 == "VALIDSIG" { print $12 }' "$status")
    [[ $signer =~ ^[0-9A-F]{40}$ ]] && grep -qx "$signer" "$tmp/trusted" || return 0
    jq -e --arg repo "$2" --arg digest "$3" '
        .critical.type == "atomic container signature"
        and .critical.image."docker-manifest-digest" == $digest
        and (.critical.identity."docker-reference" | sub("^docker\\.io/"; "") | sub("[:@].*"; "")) == $repo
    ' "$payload" > /dev/null 2>&1 || return 0
    printf '%s\n' "$signer"
}

# trust_keys KEYS: import KEYS into a fresh keyring in $tmp; only the primary keys listed at
# its top count.
trust_keys() {
    export GNUPGHOME=$tmp/gnupg
    install -d -m 700 "$GNUPGHOME"
    gpg -q --batch --import "$1"
    awk '/^#   [0-9A-F]{40} / { print $2 }' "$1" > "$tmp/trusted"
}

main() {
    local dir list arch failed=0 name ref repo index manifest n code signer signers others stored
    dir=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
    list=${1:-$dir/images}
    arch=$(docker version --format '{{.Server.Arch}}')
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    trust_keys "$dir/stagex-keys.asc"

    while read -r name ref; do
        repo=${ref%@*} index=${ref#*@}
        docker buildx imagetools inspect --raw "$ref" > "$tmp/index"
        [[ sha256:$(sha256sum < "$tmp/index" | cut -d' ' -f1) == "$index" ]] \
            || { echo "error: $name: the registry gave an index that is not $index" >&2; exit 1; }
        manifest=$(jq -r --arg arch "$arch" \
            '[.manifests[] | select(.platform.os == "linux" and .platform.architecture == $arch)] | if length == 1 then .[0].digest else empty end' "$tmp/index")
        [[ $manifest =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "error: $name: no single linux/$arch manifest in $index" >&2; exit 1; }

        signers=() others=()
        stored=$dir/sigs/$repo/${manifest#sha256:}
        [[ -d $stored ]] || echo "$name: no signatures in sigs/ for $manifest, fetching them" >&2
        for n in $(seq 1 20); do
            if [[ -d $stored ]]; then
                [[ -f $stored/signature-$n ]] || break
                cp "$stored/signature-$n" "$tmp/sig"
            else
                code=$(curl -sS --max-time 60 -o "$tmp/sig" -w '%{http_code}' "$lookaside/$repo@${manifest/:/=}/signature-$n")
                [[ $code == 404 ]] && break
                [[ $code == 200 ]] || { echo "error: $name: signature-$n: HTTP $code from $lookaside" >&2; exit 1; }
            fi
            signer=$(signature_signer "$tmp/sig" "$repo" "$manifest")
            if [[ -z $signer ]]; then
                others+=("signature-$n")   # unknown key (say a former maintainer's) or bad
            elif [[ " ${signers[*]} " != *" $signer "* ]]; then
                signers+=("$signer")
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
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi

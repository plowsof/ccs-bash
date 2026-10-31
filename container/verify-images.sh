#!/usr/bin/env bash
# verify-images.sh [--record] [IMAGES]: every pinned StageX image (default: images) must be signed
# by two or more maintainers whose keys are in stagex-keys.asc. A pin is an index digest; the
# signatures are on its linux/<arch> manifest. They are read from sigs/ (update-sigs.sh copies
# them from sigs.stagex.tools when the pins change), so a build needs nothing from that site;
# only a manifest with none stored there is looked up online. Needs gpg and jq.
# A maintainer's key that has expired since still counts for a signature we verified while it was
# valid: sigs-verified lists each stored signature (its sha256 and signer) that counted when it was
# checked (--record adds them; update-sigs.sh runs it), committed with sigs/, so git says when.
# Not a signature that only arrives after the key expired (its date is the signer's to write),
# and never one by a revoked key: a key's expiry mustn't stop every build.
set -euo pipefail
quorum=2
lookaside=https://sigs.stagex.tools

# signature_signer FILE REPO MANIFEST: print "<primary key fingerprint> good" if FILE holds exactly
# one good signature, by a key in $tmp/trusted, naming REPO and MANIFEST; "<fingerprint> recorded"
# if that key has expired since and FILE is in $verified (sigs-verified) with it; else nothing.
# Exactly one: a file can hold the same maintainer's signature twice, which must not count twice.
signature_signer() {
    local status=$tmp/status payload=$tmp/payload signer good expired kind=good
    rm -f "$payload"
    gpg --batch --status-file "$status" --output "$payload" --decrypt "$1" 2> /dev/null || return 0
    good=$(grep -c '^\[GNUPG:\] GOODSIG ' "$status" || true) expired=$(grep -c '^\[GNUPG:\] EXPKEYSIG ' "$status" || true)
    [[ $(grep -c '^\[GNUPG:\] NEWSIG' "$status") == 1 && $(grep -c '^\[GNUPG:\] VALIDSIG ' "$status") == 1 \
        && $((good + expired)) == 1 ]] || return 0
    signer=$(awk '$2 == "VALIDSIG" { print $12 }' "$status")
    [[ $signer =~ ^[0-9A-F]{40}$ ]] && grep -qx "$signer" "$tmp/trusted" || return 0
    if ((expired)); then
        grep -qxF "$(sha256sum < "$1" | cut -d' ' -f1) $signer" "${verified:-/nonexistent}" 2> /dev/null || return 0
        kind=recorded
    fi
    jq -e --arg repo "$2" --arg digest "$3" '
        .critical.type == "atomic container signature"
        and .critical.image."docker-manifest-digest" == $digest
        and (.critical.identity."docker-reference" | sub("^docker\\.io/"; "") | sub("[:@].*"; "")) == $repo
    ' "$payload" > /dev/null 2>&1 || return 0
    printf '%s %s\n' "$signer" "$kind"
}

# trust_keys KEYS: import KEYS into a fresh keyring in $tmp; only the primary keys listed at
# its top count.
trust_keys() {
    export GNUPGHOME=$tmp/gnupg
    install -d -m 700 "$GNUPGHOME"
    gpg -q --batch --import "$1"
    # (sed, not awk: Debian 12's mawk has no {40})
    sed -nE 's/^#   ([0-9A-F]{40}) .*/\1/p' "$1" > "$tmp/trusted"
}

main() {
    local dir list arch failed=0 name ref repo index manifest n code signer kind signers others stored record=''
    dir=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
    if [[ ${1:-} == --record ]]; then record=1; shift; fi
    local rec
    list=${1:-$dir/images}
    verified=$dir/sigs-verified   # global: signature_signer reads it
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

        signers=() others=() rec=0
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
            read -r signer kind <<<"$(signature_signer "$tmp/sig" "$repo" "$manifest")" || true
            # --record: a stored signature that counts now, by a key valid now, is one we verified
            if [[ $record && $kind == good && -d $stored ]]; then
                [[ -f $verified ]] || printf '%s\n' "# the stored StageX signatures (sigs/) verified while their maintainer's key was valid: sha256 of" \
                    "# the signature file, then its signer. verify-images.sh --record adds them (update-sigs.sh runs it); a" \
                    "# signature listed here still counts once its key has expired, as git dates when it was added" > "$verified"
                grep -qxF "$(sha256sum < "$tmp/sig" | cut -d' ' -f1) $signer" "$verified" 2> /dev/null \
                    || printf '%s %s\n' "$(sha256sum < "$tmp/sig" | cut -d' ' -f1)" "$signer" >> "$verified"
            fi
            if [[ -z $signer ]]; then
                others+=("signature-$n")   # unknown key (say a former maintainer's) or bad
            elif [[ " ${signers[*]} " != *" $signer "* ]]; then
                signers+=("$signer")
                [[ $kind == recorded ]] && rec=$((rec + 1))
            fi
        done
        if (( ${#signers[@]} >= quorum )); then
            echo "$name: ${#signers[@]} maintainers signed $manifest$( ((rec)) && echo " ($rec by a key that has expired since, a signature verified before: sigs-verified)")" >&2
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

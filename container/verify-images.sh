#!/usr/bin/env bash
# verify-images.sh [--record] [IMAGES]: every pinned StageX image (default: images) must be signed
# by two or more maintainers whose keys are in stagex-keys.asc. A pin is an index digest; the
# signatures are on its linux/<arch> manifest. They are read from sigs/ (update-sigs.sh copies
# them from sigs.stagex.tools when the pins change), so a build needs nothing from that site;
# only a manifest with none stored there is looked up online. Needs gpg and jq.
#
# A key that expires doesn't stop the builds: a signature we verified while its key was valid
# still counts. sigs-verified lists those ("<sha256 of the signature file> <signer>"); --record
# adds every stored signature that counts now (update-sigs.sh runs it), and git dates each line.
# A signature first seen after its key expired doesn't count (a signature's date is the signer's
# to write), nor one by a revoked key.
set -euo pipefail
quorum=2
lookaside=https://sigs.stagex.tools

# status_count WORD: how many times gpg's status file says WORD
status_count() { grep -cE "^\[GNUPG:\] $1( |$)" "$tmp/status" || true; }
# sha256 FILE: its sha256
sha256() { sha256sum < "$1" | cut -d' ' -f1; }
# recorded FILE SIGNER: sigs-verified lists FILE as SIGNER's (verified while the key was valid)
recorded() { grep -qxF "$(sha256 "$1") $2" "$verified" 2> /dev/null; }
# record FILE SIGNER: list it there, once
record() { recorded "$1" "$2" || echo "$(sha256 "$1") $2" >> "$verified"; }

# signature_signer FILE REPO MANIFEST: if FILE holds exactly one valid signature, by a key in
# $tmp/trusted, naming REPO and MANIFEST, print "<the key's fingerprint> good", or "<...> expired"
# when the key has expired since and sigs-verified lists FILE; else nothing. Exactly one: a file
# can hold the same maintainer's signature twice, which must not count twice.
signature_signer() {
    local payload=$tmp/payload signer kind
    rm -f "$payload"
    gpg --batch --status-file "$tmp/status" --output "$payload" --decrypt "$1" 2> /dev/null || return 0
    [[ $(status_count NEWSIG) == 1 && $(status_count VALIDSIG) == 1 ]] || return 0
    # by a key valid now, or one that has expired since (a revoked key's: neither)
    if [[ $(status_count GOODSIG) == 1 ]]; then kind=good
    elif [[ $(status_count EXPKEYSIG) == 1 ]]; then kind=expired
    else return 0
    fi
    signer=$(awk '$2 == "VALIDSIG" { print $12 }' "$tmp/status")
    [[ $signer =~ ^[0-9A-F]{40}$ ]] && grep -qx "$signer" "$tmp/trusted" || return 0
    # an expired key's signature only if we verified it while the key was valid
    [[ $kind == good ]] || recorded "$1" "$signer" || return 0
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
    local dir list arch failed=0 name ref repo index manifest n code signer kind signers others stored
    local recording='' expired note
    dir=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
    if [[ ${1:-} == --record ]]; then recording=1; shift; fi
    list=${1:-$dir/images}
    verified=$dir/sigs-verified   # (a global: recorded reads it)
    arch=$(docker version --format '{{.Server.Arch}}')
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    trust_keys "$dir/stagex-keys.asc"
    if [[ $recording && ! -f $verified ]]; then
        printf '%s\n' "# StageX signatures in sigs/ verified while their key was valid, \"<sha256 of the file> <signer>\":" \
            "# each still counts once its key has expired (verify-images.sh; --record adds them)" > "$verified"
    fi

    while read -r name ref; do
        repo=${ref%@*} index=${ref#*@}
        docker buildx imagetools inspect --raw "$ref" > "$tmp/index"
        [[ sha256:$(sha256 "$tmp/index") == "$index" ]] \
            || { echo "error: $name: the registry gave an index that is not $index" >&2; exit 1; }
        manifest=$(jq -r --arg arch "$arch" \
            '[.manifests[] | select(.platform.os == "linux" and .platform.architecture == $arch)] | if length == 1 then .[0].digest else empty end' "$tmp/index")
        [[ $manifest =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "error: $name: no single linux/$arch manifest in $index" >&2; exit 1; }

        signers=() others=() expired=0
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
            signer='' kind=''
            read -r signer kind < <(signature_signer "$tmp/sig" "$repo" "$manifest") || true
            if [[ $recording && $kind == good && -d $stored ]]; then record "$tmp/sig" "$signer"; fi
            if [[ -z $signer ]]; then
                others+=("signature-$n")   # unknown key (say a former maintainer's) or bad
            elif [[ " ${signers[*]} " != *" $signer "* ]]; then
                signers+=("$signer")
                if [[ $kind == expired ]]; then expired=$((expired + 1)); fi
            fi
        done
        if (( ${#signers[@]} >= quorum )); then
            note=''
            ((expired == 0)) || note=" ($expired by a key that has expired since, verified before it did)"
            echo "$name: ${#signers[@]} maintainers signed $manifest$note" >&2
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

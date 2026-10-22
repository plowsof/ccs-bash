#!/usr/bin/env bash
# update-keys.sh: refresh stagex-keys.asc, the public keys of StageX's maintainers, which
# verify-images.sh checks the image signatures against. The fingerprints come from the
# MAINTAINERS file in StageX's own repo, the keys from keys.openpgp.org by fingerprint.
# Review the diff before committing it: a new fingerprint is a new person trusted to sign.
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export GNUPGHOME=$tmp/gnupg
install -d -m 700 "$GNUPGHOME"

curl -fsSL --max-time 60 https://codeberg.org/stagex/stagex/raw/branch/main/MAINTAINERS -o "$tmp/MAINTAINERS"
awk -F'"' '/^\[keys\./ { key = $0 } /^id = / { print $2, key }' "$tmp/MAINTAINERS" > "$tmp/fprs"
while read -r fpr key; do
    [[ $fpr =~ ^[0-9A-F]{40}$ ]] || { echo "error: $key: not a fingerprint: $fpr" >&2; exit 1; }
    curl -fsSL --max-time 60 "https://keys.openpgp.org/vks/v1/by-fingerprint/$fpr" -o "$tmp/$fpr.asc" \
        || { echo "warning: $key $fpr is not on keys.openpgp.org, left out" >&2; continue; }
    gpg -q --batch --import "$tmp/$fpr.asc"
    gpg --batch --with-colons --fingerprint "$fpr" | grep -q "^fpr:::::::::$fpr:" \
        || { echo "error: keys.openpgp.org gave another key for $fpr" >&2; exit 1; }
    echo "$fpr $key"
done < "$tmp/fprs" > "$tmp/kept"

mapfile -t fprs < <(cut -d' ' -f1 "$tmp/kept")
{
    echo "# StageX maintainers' public keys, from container/update-keys.sh. Primary key fingerprints:"
    sed 's/^/#   /' "$tmp/kept"
    gpg --batch --armor --export-options export-minimal --export "${fprs[@]}"
} > "$here/stagex-keys.asc"
git -C "$here" diff --stat -- stagex-keys.asc >&2

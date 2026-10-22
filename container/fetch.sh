#!/usr/bin/env bash
# fetch.sh DIR: download every file in deps.lock into DIR with plain curl, no apt.
# Each file's urls are tried in order; a download only counts if its sha256 matches
# the lock, so a mirror can't hand over a different file.
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
out=$1
mkdir -p "$out"

grep -v '^#' "$here/deps.lock" | while read -r sum size urls; do
    read -ra urls <<<"$urls"
    file=$out/$(basename "${urls[0]}" | sed 's/%2b/+/g; s/%7e/~/g; s/%3a/:/g')
    if [[ -f $file ]] && echo "$sum  $file" | sha256sum -c --status; then
        continue
    fi
    for url in "${urls[@]}"; do
        if curl -fsSL --max-time 300 -o "$file.part" "$url" && echo "$sum  $file.part" | sha256sum -c --status; then
            mv "$file.part" "$file"
            break
        fi
        echo "warning: $url failed or did not match, trying the next one" >&2
    done
    rm -f "$file.part"
    [[ -f $file ]] || { echo "error: no url gave $(basename "$file") with sha256 $sum ($size bytes)" >&2; exit 1; }
done
"$here/verify.sh" "$here/deps.lock" "$out"

#!/usr/bin/env bash
# fetch.sh DIR: download every file in sources.lock into DIR with plain curl. Each file's
# urls are tried in order; a download only counts if its sha256 matches the lock.
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
out=$1
mkdir -p "$out"

grep -v '^#' "$here/sources.lock" | while read -r sum size urls; do
    read -ra urls <<<"$urls"
    file=$out/$(basename "${urls[0]}")
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
"$here/verify.sh" "$here/sources.lock" "$out"

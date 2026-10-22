#!/usr/bin/env bash
# verify.sh LOCK DIR: check that DIR holds exactly the files in LOCK, each with its sha256.
# Used by fetch.sh after downloading and again inside the offline build (busybox there:
# so no GNU-only options).
set -euo pipefail
lock=$1 dir=$2
n=0
while read -r sum _ url _; do
    file=$(basename "$url")
    echo "$sum  $dir/$file" | sha256sum -c - > /dev/null 2>&1 || { echo "error: $file missing or wrong sha256" >&2; exit 1; }
    n=$((n + 1))
done < <(grep -v '^#' "$lock")
[[ $(find "$dir" -maxdepth 1 -type f | wc -l) -eq $n ]] || { echo "error: $dir has files that are not in $lock" >&2; exit 1; }
echo "$n files match $lock" >&2

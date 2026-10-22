#!/usr/bin/env bash
# verify.sh LOCK DIR: DIR holds exactly LOCK's files, with their sha256. Also runs inside
# the build, on busybox: no GNU-only options.
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

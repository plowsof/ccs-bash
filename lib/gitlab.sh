# shellcheck shell=bash
# GitLab API: open MRs become "Ideas", merged MRs give each proposal its gitlab-url.
# The proposals repo is public, so no token is needed.
#
# Functions that can fail return non-zero explicitly: they are called from
# `|| ...` contexts, where bash ignores `set -e`.

gitlab_get() {
    curl -fsS --max-time 30 "$REPOSITORY_URL/$1"
}

# All MRs in state $1 (opened or merged), most recently updated first.
gitlab_mrs() {
    local page=1 batch all='[]'
    while :; do
        batch=$(gitlab_get "merge_requests?state=$1&scope=all&order_by=updated_at&per_page=100&page=$page") || return 1
        all=$(jq -s 'add' <<<"$all $batch") || return 1
        [[ $(jq length <<<"$batch") -eq 100 ]] || break
        page=$((page + 1))
    done
    printf '%s\n' "$all"
}

# Print the proposal file MR $1 adds, or nothing if it is not a proposal MR.
# A proposal MR adds exactly one new .md file in the repo root.
mr_proposal_file() {
    local files
    files=$(gitlab_get "merge_requests/$1/changes" | jq -r '.changes[] | select(.new_file) | .new_path') || return 1
    if [[ $files != *$'\n'* ]] && safe_filename "$files"; then
        printf '%s\n' "$files"
    fi
}

# Print the URL of the merged MR that added proposal file $1, or nothing.
# The merged MR list, and which file each MR added, are fetched once per run.
merged_mr_url() {
    local iid url file cache=$WORK/merged-files.tsv
    if [[ ! -s $WORK/merged.json ]]; then
        gitlab_mrs merged > "$WORK/merged.tmp" || return 1
        mv "$WORK/merged.tmp" "$WORK/merged.json"
        : > "$cache"
    fi
    while IFS=$'\t' read -r iid url; do
        if ! file=$(awk -F'\t' -v i="$iid" '$1 == i { print $2; found = 1 } END { exit !found }' "$cache"); then
            file=$(mr_proposal_file "$iid") || return 1
            printf '%s\t%s\n' "$iid" "$file" >> "$cache"
        fi
        if [[ $file == "$1" ]]; then
            printf '%s\n' "$url"
            return 0
        fi
    done < <(jq -r '.[] | [.iid, .web_url] | @tsv' "$WORK/merged.json")
}

# Print the "Ideas" list for ccs-front: open MRs adding a proposal that is not merged yet.
ideas() {
    local mrs iid file keep=()
    mrs=$(gitlab_mrs opened) || return 1
    while read -r iid; do
        # One MR that can't be read is left out this time, not the whole list frozen.
        if ! file=$(mr_proposal_file "$iid"); then
            log "warning: could not read MR !$iid, leaving it out of the ideas this run"
            continue
        fi
        if [[ -n $file && ! -e $PROPOSALS_DIR/$file ]]; then
            keep+=("$iid")
        fi
    done < <(jq -r '.[].iid' <<<"$mrs")

    jq --argjson keep "$(printf '%s\n' "${keep[@]}" | jq -s .)" '
        map(select(.iid | IN($keep[])) | {
            name: (.title | sub("^\\s+"; "") | sub("\\s+$"; "") | @html),
            "gitlab-url": (.web_url | if type == "string" and test("^https://[^\\s\"\\x27<>\\\\]+$") then @html else null end),
            author: (.author.username | @html),
            date: (.created_at | sub("\\.[0-9]+"; "") | fromdate | strftime("%B %-d, %Y")),
            ts: (.created_at | sub("\\.[0-9]+"; "") | fromdate)
        }) | sort_by(-.ts) | map(del(.ts))' <<<"$mrs"
}

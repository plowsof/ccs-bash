# shellcheck shell=bash
# GitLab API (public, no token): open MRs are "Ideas", merged MRs give each proposal its
# gitlab-url. Failures return non-zero explicitly: callers use `||`, where set -e is off.
#
# Or Forgejo / Gitea (git.disroot.org, codeberg.org...), told apart by REPOSITORY_URL:
# .../api/v4/projects/<id> is GitLab, .../api/v1/repos/<owner>/<repo> is Forgejo. Its pull
# requests are turned into GitLab's shape as they arrive (iid, web_url, author.username,
# created_at in UTC), so everything after this file is the same for both.

gitlab_get() {
    curl -fsS --max-time 30 "$REPOSITORY_URL/$1"
}

forgejo() { [[ ${REPOSITORY_URL:-} =~ /api/v1/repos/[^/]+/[^/]+/?$ ]]; }

# All MRs in state $1 (opened or merged), most recently updated first.
gitlab_mrs() {
    local page=1 batch all='[]'
    if forgejo; then
        forgejo_prs "$1"
        return
    fi
    while :; do
        batch=$(gitlab_get "merge_requests?state=$1&scope=all&order_by=updated_at&per_page=100&page=$page") || return 1
        all=$(jq -s 'add' <<<"$all $batch") || return 1
        [[ $(jq length <<<"$batch") -eq 100 ]] || break
        page=$((page + 1))
    done
    printf '%s\n' "$all"
}

# Forgejo: pull requests open, or merged (closed and merged), as GitLab MRs. At most 50 a
# page (Forgejo's default limit); a full page means there may be another.
forgejo_prs() {
    local page=1 batch all='[]' state=open
    [[ $1 == opened ]] || state=closed
    while :; do
        batch=$(gitlab_get "pulls?state=$state&sort=recentupdate&limit=50&page=$page") || return 1
        all=$(jq -s --arg want "$1" '.[0] + (.[1] | map(select($want == "opened" or .merged == true) | {
            iid: .number, web_url: .html_url, title, author: {username: .user.login},
            # 2026-10-16T15:20:32+02:00 -> 2026-10-16T13:20:32Z (jq reads only Z times)
            created_at: (.created_at | if . == null then null else capture("^(?<t>[0-9-]{10}T[0-9:]{8})(\\.[0-9]+)?(?<z>Z|(?<s>[+-])(?<h>[0-9]{2}):(?<m>[0-9]{2}))$")
                | (.t + "Z" | fromdate) - (if .z == "Z" then 0 else (.s + "1" | tonumber) * ((.h | tonumber) * 3600 + (.m | tonumber) * 60) end)
                | todate end)
        }))' <<<"$all $batch") || return 1
        [[ $(jq length <<<"$batch") -eq 50 ]] || break
        page=$((page + 1))
    done
    printf '%s\n' "$all"
}

# Print the proposal file MR $1 adds: exactly one new .md in the repo root, else nothing.
mr_proposal_file() {
    local files
    if forgejo; then
        files=$(gitlab_get "pulls/$1/files?limit=50" | jq -r '.[] | select(.status == "added") | .filename') || return 1
    else
        files=$(gitlab_get "merge_requests/$1/changes" | jq -r '.changes[] | select(.new_file) | .new_path') || return 1
    fi
    if [[ $files != *$'\n'* ]] && safe_filename "$files"; then
        printf '%s\n' "$files"
    fi
}

# Print the URL of the merged MR that added file $1, or nothing. Fetched once per run.
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
        # an unreadable MR is left out, not the whole list
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

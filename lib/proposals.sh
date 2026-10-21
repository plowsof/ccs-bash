# shellcheck shell=bash
# Proposal files -> JSON array of proposals, plus the address mapping state.

# Print a JSON array with one object per valid proposal file in directory $1.
read_proposals() {
    local file
    for file in "$1"/*.md; do
        safe_filename "${file##*/}" || { log "skipping ${file##*/}: bad filename"; continue; }
        printf '%s\0' "$file"
    done | xargs -0 -r awk -f "$CCS_LIB/frontmatter.awk" | jq -R -s '
        split("\n") | map(select(. != "") | split("\t") | {
            file: .[0],
            layout: .[1],
            title: .[2],
            author: .[3],
            ts: (if .[4] == "" then 0 else .[4] | split(" ") | map(tonumber) | .[1] -= 1 | . + [0, 0, 0, 0, 0] | mktime end),
            amount: (.[5] | tonumber),
            gitlab_url: (if .[6] == "" then null else .[6] end),
            milestones: (.[7] | tonumber),
            done: (.[8] | tonumber)
        })'
}

# The state file has one line per proposal we have seen:
#   filename <TAB> gitlab_url <TAB> subaddr_index <TAB> address
# It is the only data that cannot be recomputed. While running it is kept as
# JSON in $WORK/state.json: {"file.md": {gitlab_url, subaddr_index, address}}.
load_state() {
    [[ -e $STATE_DIR/proposals.tsv ]] || : > "$STATE_DIR/proposals.tsv"
    jq -R -s '
        split("\n") | map(select(. != "") | split("\t") | {key: .[0], value: {
            gitlab_url: (if (.[1] // "") == "" then null else .[1] end),
            subaddr_index: (if (.[2] // "") == "" then null else .[2] | tonumber end),
            address: (if (.[3] // "") == "" then null else .[3] end)
        }}) | from_entries' "$STATE_DIR/proposals.tsv" > "$WORK/state.json"
}

save_state() {
    jq -r 'to_entries[] | [.key, .value.gitlab_url, .value.subaddr_index, .value.address] | map(. // "") | @tsv' \
        "$WORK/state.json" | atomic_write "$STATE_DIR/proposals.tsv"
}

# state_update [jq options] FILTER: change the state with a jq filter and save it.
state_update() {
    jq "$@" "$WORK/state.json" > "$WORK/state.new" && mv "$WORK/state.new" "$WORK/state.json" && save_state
}

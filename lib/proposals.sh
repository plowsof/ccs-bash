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
            amount: .[5],
            gitlab_url: (if .[6] == "" then null else .[6] end),
            milestones: (.[7] | tonumber),
            done: (.[8] | tonumber)
        })'
}

# The state file, proposals.csv, has one line per proposal we have seen:
#   filename,gitlab_url,subaddr_index,address,funding_required_date
# Values with a comma or a quote are quoted, as jq's @csv writes them (a real
# proposal filename has commas). funding_required_date is when the proposal was
# first seen as "fr", e.g. 2026-01-07T12:36:31Z. Empty fields mean unknown / none.
# It is the only data that cannot be recomputed. While running it is kept as JSON
# in $WORK/state.json: {"file.md": {gitlab_url, subaddr_index, address, funding_required_date}}.
load_state() {
    [[ -e $STATE_DIR/proposals.csv ]] || : > "$STATE_DIR/proposals.csv"
    # A line is read by matching ,field repeatedly after putting a comma in front:
    # a field is either "quoted, with "" for a quote" or anything up to the next comma.
    # (The extra comma avoids empty matches, which jq 1.6 and 1.7 handle differently.)
    jq -R -s '
        def csvrow: [("," + .) | match(",(\"(?:[^\"]|\"\")*\"|[^,]*)"; "g") | (.captures[0].string // "")
                     | if startswith("\"") then .[1:-1] | gsub("\"\""; "\"") else . end];
        def opt: if . == "" then null else . end;
        split("\n") | map(select(. != "") | csvrow | {key: .[0], value: {
            gitlab_url: (.[1] // "" | opt),
            subaddr_index: (.[2] // "" | opt | if . then tonumber else . end),
            address: (.[3] // "" | opt),
            funding_required_date: (.[4] // "" | opt)
        }}) | from_entries' "$STATE_DIR/proposals.csv" > "$WORK/state.json"
}

save_state() {
    jq -r 'to_entries[] | [.key, .value.gitlab_url, .value.subaddr_index, .value.address, .value.funding_required_date] | map(. // "") | @csv' \
        "$WORK/state.json" | atomic_write "$STATE_DIR/proposals.csv"
}

# state_update [jq options] FILTER: change the state with a jq filter and save it.
state_update() {
    jq "$@" "$WORK/state.json" > "$WORK/state.new" && mv "$WORK/state.new" "$WORK/state.json" && save_state
}

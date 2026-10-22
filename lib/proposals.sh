# shellcheck shell=bash
# Proposal files -> JSON array of proposals, plus the address mapping state.

# Print a JSON array with one object per valid proposal file in directory $1.
read_proposals() {
    local file i files=() names=() utf8
    for file in "$1"/*.md; do
        [[ -e $file || -L $file ]] || continue # no .md files at all
        # a directory, fifo or symlink named like a proposal would stop or hang the run
        [[ -f $file && ! -L $file ]] || { log "skipping ${file##*/}: not a plain file"; continue; }
        safe_filename "${file##*/}" || { log "skipping ${file##*/}: bad filename"; continue; }
        files+=("$file") names+=("${file##*/}")
    done
    # Not valid UTF-8: jq would turn the bad bytes into U+FFFD, so two different names could
    # end up as one (and share an address). jq's copy differs from the name exactly then.
    if ((${#names[@]})); then
        mapfile -t utf8 < <(printf '%s\n' "${names[@]}" | jq -Rr .)
        for i in "${!names[@]}"; do
            if [[ ${utf8[i]} != "${names[i]}" ]]; then
                log "skipping ${utf8[i]}: filename is not valid UTF-8"
                unset 'files[i]'
            fi
        done
    fi
    if ((${#files[@]} == 0)); then
        echo '[]'
        return
    fi
    printf '%s\0' "${files[@]}" | xargs -0 -r awk -f "$CCS_LIB/frontmatter.awk" | jq -R -s '
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
    # Never recreated here: without it every funding-required proposal would quietly get a new
    # address. A fresh install creates it empty; otherwise it has to come back from a backup.
    [[ -e $STATE_DIR/proposals.csv ]] \
        || die "no $STATE_DIR/proposals.csv: restore it from a backup, or on a fresh install create it empty"
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
        }})
        | map(if (.value.funding_required_date // "2000-01-01T00:00:00Z") | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")
              then . else error("bad funding_required_date for \(.key): \(.value.funding_required_date)") end)
        | from_entries' "$STATE_DIR/proposals.csv" > "$WORK/state.json"
}

save_state() {
    atomic_write "$STATE_DIR/proposals.csv" jq -r \
        'to_entries[] | [.key, .value.gitlab_url, .value.subaddr_index, .value.address, .value.funding_required_date] | map(. // "") | @csv' \
        "$WORK/state.json"
}

# state_update [jq options] FILTER: change the state with a jq filter and save it.
state_update() {
    jq "$@" "$WORK/state.json" > "$WORK/state.new" && mv "$WORK/state.new" "$WORK/state.json" && save_state
}

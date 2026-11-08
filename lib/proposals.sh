# shellcheck shell=bash
# Proposal files -> JSON array of proposals, plus the address mapping state.

# Print a JSON array with one object per valid proposal file in directory $1.
read_proposals() {
    local file i files=() names=() utf8
    for file in "$1"/*.md; do
        [[ -e $file || -L $file ]] || continue # no .md files at all
        # Skip anything that isn't a plain file: a directory, fifo or symlink could hang the run.
        [[ -f $file && ! -L $file ]] || { log "skipping ${file##*/}: not a plain file"; continue; }
        safe_filename "${file##*/}" || { log "skipping ${file##*/}: bad filename"; continue; }
        files+=("$file") names+=("${file##*/}")
    done
    # Skip names that aren't valid UTF-8. jq turns bad bytes into U+FFFD, so two names could
    # become one and share an address. jq's copy of the name differs exactly in that case.
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
            done: (.[8] | tonumber),
            tags: (.[9] // "" | if . == "" then [] else split("\u001f") end)
        })'
}

# The state file, proposals.csv, has one line per proposal ever seen, written by jq's @csv
# (filenames can contain commas). An empty field means unknown.
#   filename,gitlab_url,subaddr_index,address,funding_required_date[,funded_date]
# funding_required_date: when first seen in Funding Required (UTC).
# funded_date: when first seen fully funded (UTC). The column is added only once it is set.
# During a run the state is $WORK/state.json: {"file.md": {gitlab_url, subaddr_index, ...}}.
load_state() {
    # Never recreate it: every Funding Required proposal would quietly get a new address.
    # Restore a backup instead.
    [[ -e $STATE_DIR/proposals.csv ]] \
        || die "no $STATE_DIR/proposals.csv: restore it from a backup, or on a fresh install create it empty"
    # Parse CSV: match ",field" repeatedly on "," + line. A field is either quoted ("" for a
    # quote inside) or runs to the next comma. The leading comma avoids empty matches,
    # which jq 1.6 and 1.7 handle differently.
    jq -R -s '
        def csvrow: [("," + .) | match(",(\"(?:[^\"]|\"\")*\"|[^,]*)"; "g") | (.captures[0].string // "")
                     | if startswith("\"") then .[1:-1] | gsub("\"\""; "\"") else . end];
        def opt: if . == "" then null else . end;
        split("\n") | map(select(. != "") | csvrow | {key: .[0], value: {
            gitlab_url: (.[1] // "" | opt),
            subaddr_index: (.[2] // "" | opt | if . then tonumber else . end),
            address: (.[3] // "" | opt),
            funding_required_date: (.[4] // "" | opt),
            funded_date: (.[5] // "" | opt)
        }})
        | map(.key as $k | reduce ("funding_required_date", "funded_date") as $c (.;
              if (.value[$c] // "2000-01-01T00:00:00Z") | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")
              then . else error("bad \($c) for \($k): \(.value[$c])") end))
        | from_entries' "$STATE_DIR/proposals.csv" > "$WORK/state.json"
}

save_state() {
    atomic_write "$STATE_DIR/proposals.csv" jq -r \
        'to_entries[] | [.key, .value.gitlab_url, .value.subaddr_index, .value.address, .value.funding_required_date]
             + (if .value.funded_date then [.value.funded_date] else [] end) | map(. // "") | @csv' \
        "$WORK/state.json"
}

# state_update [jq options] FILTER: change the state with a jq filter and save it.
state_update() {
    jq "$@" "$WORK/state.json" > "$WORK/state.new" && mv "$WORK/state.new" "$WORK/state.json" && save_state
}

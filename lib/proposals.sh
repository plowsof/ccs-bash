# shellcheck shell=bash
# Proposal files -> JSON array of proposals, plus the address mapping state.

# ccs_back_splits FILE: true if ccs-back could find its front matter: preg_split on
# \r?\n?---\r?\n must find two "---" + new line. A file whose closing --- is its last line, with
# no new line after it, it never read (shown under Ideas, it never reached Funding Required):
# here, the same. Plain bash, no od or the like (the image has busybox only).
ccs_back_splits() {
    local s rest
    s=$(cat -- "$1"; echo x) || return 1
    s=${s%x}
    s=${s//$'\r\n'/$'\n'}
    rest=${s#*$'---\n'}
    [[ $rest != "$s" && $rest == *$'---\n'* ]]
}

# Print a JSON array with one object per valid proposal file in directory $1.
read_proposals() {
    local file i files=() names=() utf8
    for file in "$1"/*.md; do
        [[ -e $file || -L $file ]] || continue # no .md files at all
        # a directory, fifo or symlink named like a proposal would stop or hang the run
        [[ -f $file && ! -L $file ]] || { log "skipping ${file##*/}: not a plain file"; continue; }
        safe_filename "${file##*/}" || { log "skipping ${file##*/}: bad filename"; continue; }
        ccs_back_splits "$file" \
            || { log "skipping ${file##*/}: no front matter closed by a line --- with a new line after it"; continue; }
        files+=("$file") names+=("${file##*/}")
    done
    # Not UTF-8: jq would turn bad bytes into U+FFFD, so two names could become one (and
    # share an address). Exactly then jq's copy differs from the name.
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

# The state, proposals.csv, one line per proposal seen (as jq's @csv writes it; filenames
# can have commas), empty = unknown:
#   filename,gitlab_url,subaddr_index,address,funding_required_date   (first seen as fr, UTC)
# During a run it is $WORK/state.json: {"file.md": {gitlab_url, subaddr_index, ...}}.
load_state() {
    # Never recreated: every fr proposal would quietly get a new address. Restore a backup.
    [[ -e $STATE_DIR/proposals.csv ]] \
        || die "no $STATE_DIR/proposals.csv: restore it from a backup, or on a fresh install create it empty"
    # Match ,field repeatedly on "," + line; a field is "quoted ("" inside)" or up to the
    # next comma. (The leading comma avoids empty matches, which jq 1.6 and 1.7 differ on.)
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

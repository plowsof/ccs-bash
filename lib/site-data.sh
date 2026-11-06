# shellcheck shell=bash
# The site's JSON (what ccs-front-bash builds the site from), from site-data.json: as ccs-back.sh's
# build_site writes it, but each proposal's address the signed list's line of its index. The web
# server builds the site this way itself, from the proposals repository it
# fetches and the site-data.json it checked; tests/run.sh and contrib/compare-site check that it
# gives the same JSON as the backend's own run.

# site_json: OUTPUT_DIR's proposals.json, completed-proposals.json and projects.json from WORK's
# props, state, funds and ideas (lib/site.jq)
site_json() {
    local out
    for out in proposals completed-proposals projects; do
        atomic_write "$OUTPUT_DIR/$out.json" jq -n --indent 4 --arg out "$out" \
            --slurpfile props "$WORK/props.json" --slurpfile state "$WORK/state.json" \
            --slurpfile funds "$WORK/funds.json" \
            --slurpfile ideas "$WORK/ideas.json" -f "$CCS_LIB/site.jq"
    done
}

# merge_requests GIT BASE REPOS: {"file.md": link} for each proposal the proposals repository GIT
# (its refs/heads/ccs) merged: the merge request of the merge commit that added the file (GitLab
# ends its message "See merge request <project>!N"), as BASE/<project>/-/merge_requests/N, only
# for a project REPOS names (host/path, space-separated: the proposals repository's own addresses;
# a commit message naming another project, anyone's on that forge, links nowhere). The oldest
# one: a later merge request that adds a file of the same name isn't this proposal's. A proposal
# added by a commit that isn't a merge (moved, renamed) has none.
merge_requests() {
    git -C "$1" -c core.quotePath=false log --first-parent --merges --diff-merges=first-parent --diff-filter=A \
        --name-only --format='%x01%n%B%x02' refs/heads/ccs \
        | awk -v base="${2%/}" -v repos=" ${3:-} " '
            /^\001$/ { mr = ""; files = 0; next }
            !files {
                if (match($0, /See merge request [A-Za-z0-9._-]+(\/[A-Za-z0-9._-]+)+![0-9]+/)) {
                    s = substr($0, RSTART + 18, RLENGTH - 18); i = index(s, "!"); p = substr(s, 1, i - 1)
                    h = base; sub(/^https:\/\//, "", h)
                    # (no step out of the path, and one of the repositories named)
                    if (p !~ /(^|\/)\.\.?(\/|$)/ && index(repos, " " h "/" p " "))
                        mr = base "/" p "/-/merge_requests/" substr(s, i + 1)
                }
                if (/\002$/) files = 1
                next
            }
            mr != "" && /\.md$/ && !/\// { link[$0] = mr }
            END { for (f in link) print f "\t" link[f] }' \
        | jq -R -n '[inputs | split("\t") | {key: .[0], value: .[1]}] | from_entries'
}

# site_from_data DATA LIST [LINKS]: OUTPUT_DIR's site JSON and images (images.json, images/) from
# the proposals in PROPOSALS_DIR, DATA (site-data.json) and LIST (the signed list, "index address"
# lines): the backend's own steps (read_proposals, proposal_images, site_json), its state each
# address the list's, and each merge request LINKS' (merge_requests' JSON), if given; a Funding
# Required proposal without an address kept off the site, as the backend keeps it (mirror_hide)
site_from_data() {
    local data=$1 list=$2 links=${3:-}
    read_proposals "$PROPOSALS_DIR" > "$WORK/props.json" || return 1
    jq -n --slurpfile d "$data" --rawfile l "$list" --slurpfile m "${links:-/dev/null}" --arg links "$links" '
        ($l | split("\n") | map(split(" ") | select(length >= 2) | {key: .[0], value: .[1]}) | from_entries) as $at
        | $d[0].state | to_entries | map(.key as $f | .value |= (. + {address: (if .subaddr_index == null then null else $at[.subaddr_index | tostring] end)}
            + if $links == "" then {} else {gitlab_url: ($m[0][$f] // null)} end)) | from_entries' \
        > "$WORK/state.json" || return 1
    jq '.funds' "$data" > "$WORK/funds.json" && jq '.ideas' "$data" > "$WORK/ideas.json" || return 1
    jq --slurpfile s "$WORK/state.json" 'map(select(.layout != "fr" or ($s[0][.file].address // null) != null))' \
        "$WORK/props.json" > "$WORK/props.tmp" && mv "$WORK/props.tmp" "$WORK/props.json" || return 1
    proposal_images || return 1
    site_json
}

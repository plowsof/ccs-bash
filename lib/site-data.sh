# shellcheck shell=bash
# Turn site-data.json into the site's JSON, which ccs-front-bash builds the pages from.
# Each proposal's address comes from the signed list, by its subaddress index.
# The web server runs this on the proposals repository it fetched and the site-data.json it checked.
# tests/run.sh and contrib/compare-site check that the result matches the backend's own run.

# site_json: write proposals.json, completed-proposals.json and projects.json into OUTPUT_DIR.
# Built from WORK's props, state, funds and ideas by lib/site.jq.
site_json() {
    local out
    for out in proposals completed-proposals projects; do
        atomic_write "$OUTPUT_DIR/$out.json" jq -n --indent 4 --arg out "$out" \
            --slurpfile props "$WORK/props.json" --slurpfile state "$WORK/state.json" \
            --slurpfile funds "$WORK/funds.json" \
            --slurpfile ideas "$WORK/ideas.json" -f "$CCS_LIB/site.jq"
    done
}

# merge_requests GIT BASE REPOS: print {"file.md": link} for proposals merged in GIT (refs/heads/ccs).
# The link is the MR of the merge commit that added the file. GitLab ends that commit's message
# with "See merge request <project>!N". The link is BASE/<project>/-/merge_requests/N.
# Only projects named in REPOS count (host/path, space-separated). Anyone can name another
# project in a commit message, so those get no link.
# The oldest MR wins: a later MR adding a file with the same name is a different proposal.
# A file added without a merge commit (moved, renamed) gets no link.
merge_requests() {
    git -C "$1" -c core.quotePath=false log --first-parent --merges --diff-merges=first-parent --diff-filter=A \
        --name-only --format='%x01%n%B%x02' refs/heads/ccs \
        | awk -v base="${2%/}" -v repos=" ${3:-} " '
            /^\001$/ { mr = ""; files = 0; next }
            !files {
                if (match($0, /See merge request [A-Za-z0-9._-]+(\/[A-Za-z0-9._-]+)+![0-9]+/)) {
                    s = substr($0, RSTART + 18, RLENGTH - 18); i = index(s, "!"); p = substr(s, 1, i - 1)
                    h = base; sub(/^https:\/\//, "", h)
                    # The path must not step out with "..", and must be one of REPOS.
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

# site_from_data DATA LIST [LINKS [REPOS]]: write the site JSON and images into OUTPUT_DIR.
# Inputs: the proposals in PROPOSALS_DIR, DATA (site-data.json) and LIST (the signed list,
# "index address" lines). It runs the backend's own steps: read_proposals, proposal_images, site_json.
# Each address comes from LIST. Each MR link comes from LINKS (merge_requests' output), if given.
# A Funding Required proposal without an address stays off the site, as on the backend (mirror_hide).
# REPOS is set on the web server: the proposals repository's addresses, host/path, space-separated.
# Then a proposal's own gitlab_url (front matter) is used only if it points into one of them.
# Otherwise the link comes from LINKS or DATA, so a proposal can't link its page elsewhere.
# A valid front matter link wins over LINKS. Example: rehrar-defcon-reimburse-2019.md was added
# by !67, removed, then added again by !69. LINKS has the oldest, !67; the front matter says !69.
site_from_data() {
    local data=$1 list=$2 links=${3:-} repos=${4-}
    read_proposals "$PROPOSALS_DIR" > "$WORK/props.json" || return 1
    jq -n --slurpfile d "$data" --rawfile l "$list" --slurpfile m "${links:-/dev/null}" --arg links "$links" '
        ($l | split("\n") | map(split(" ") | select(length >= 2) | {key: .[0], value: .[1]}) | from_entries) as $at
        | $d[0].state | to_entries | map(.key as $f | .value |= (. + {address: (if .subaddr_index == null then null else $at[.subaddr_index | tostring] end)}
            + if $links == "" then {} else {gitlab_url: ($m[0][$f] // null)} end)) | from_entries' \
        > "$WORK/state.json" || return 1
    jq '.funds' "$data" > "$WORK/funds.json" && jq '.ideas' "$data" > "$WORK/ideas.json" || return 1
    jq --slurpfile s "$WORK/state.json" --arg repos " $repos " --arg held "${4+1}" '
        map(select(.layout != "fr" or ($s[0][.file].address // null) != null)
            | if $held == "" or .gitlab_url == null then .
              else (.gitlab_url | capture("^https://(?<r>[^ ]+?)(/-/merge_requests/|/merge_requests/|/pulls/)[0-9]{1,10}$")? // {r: ""}) as $m
                | if $m.r != "" and ($repos | contains(" " + $m.r + " ")) then . else .gitlab_url = null end
              end)' \
        "$WORK/props.json" > "$WORK/props.tmp" && mv "$WORK/props.tmp" "$WORK/props.json" || return 1
    proposal_images || return 1
    site_json
}

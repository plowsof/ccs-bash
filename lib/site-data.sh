# shellcheck shell=bash
# The site's JSON (what ccs-front-bash builds the site from), from site-data.json: as ccs-back.sh's
# build_site writes it, but each proposal's address the signed list's line of its index. The web
# server is to build the site this way itself (docs: step 6), from the proposals repository it
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

# site_from_data DATA LIST: OUTPUT_DIR's site JSON and images (images.json, images/) from the
# proposals in PROPOSALS_DIR, DATA (site-data.json) and LIST (the signed list, "index address"
# lines): the backend's own steps (read_proposals, proposal_images, site_json), its state each
# address the list's; a Funding Required proposal without one kept off the site, as the backend
# keeps it (mirror_hide)
site_from_data() {
    local data=$1 list=$2
    read_proposals "$PROPOSALS_DIR" > "$WORK/props.json" || return 1
    jq -n --slurpfile d "$data" --rawfile l "$list" '
        ($l | split("\n") | map(split(" ") | select(length >= 2) | {key: .[0], value: .[1]}) | from_entries) as $at
        | $d[0].state | map_values(. + {address: (if .subaddr_index == null then null else $at[.subaddr_index | tostring] end)})' \
        > "$WORK/state.json" || return 1
    jq '.funds' "$data" > "$WORK/funds.json" && jq '.ideas' "$data" > "$WORK/ideas.json" || return 1
    jq --slurpfile s "$WORK/state.json" 'map(select(.layout != "fr" or ($s[0][.file].address // null) != null))' \
        "$WORK/props.json" > "$WORK/props.tmp" && mv "$WORK/props.tmp" "$WORK/props.json" || return 1
    proposal_images || return 1
    site_json
}

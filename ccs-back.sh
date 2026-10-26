#!/usr/bin/env bash
# ccs-back.sh [CONFIG]: one run. Reads the proposals, GitLab and a view-only wallet, writes
# the JSON into OUTPUT_DIR (ccs-front's _data). Only STATE_DIR/proposals.csv is state, which
# nothing can make again; beside it two caches, each made again when deleted: deposits.csv (the
# wallet's deposits 30 blocks deep, so a run asks only for newer ones) and ideas.cache.
set -euo pipefail
export LC_ALL=C TZ=UTC

CCS_LIB=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib
# shellcheck source=lib/common.sh
source "$CCS_LIB/common.sh"
# shellcheck source=lib/proposals.sh
source "$CCS_LIB/proposals.sh"
# shellcheck source=lib/gitlab.sh
source "$CCS_LIB/gitlab.sh"
# shellcheck source=lib/wallet.sh
source "$CCS_LIB/wallet.sh"
# shellcheck source=lib/images.sh
source "$CCS_LIB/images.sh"

# New proposals: remember their merged MR, and when funding started if already fr.
# GitLab down: tried again next run.
record_new_proposals() {
    local file layout url
    while IFS=$'\t' read -r file layout; do
        if ! url=$(merged_mr_url "$file"); then
            log "warning: GitLab lookup failed for new proposal $file, retrying next run"
            continue
        fi
        state_update --arg f "$file" --arg u "$url" --arg fr "$([[ $layout == fr ]] && now_utc)" \
            '.[$f] = {gitlab_url: (if $u == "" then null else $u end), funding_required_date: (if $fr == "" then null else $fr end)}'
        log "new proposal $file ${url:-(no merged MR found)}"
    done < <(jq -r --slurpfile state "$WORK/state.json" '.[] | select($state[0][.file] == null) | [.file, .layout] | @tsv' "$WORK/props.json")
}

# GitLab down: keep the last run's Ideas.
previous_ideas() {
    jq '.[0].proposals' "$OUTPUT_DIR/proposals.json" 2> /dev/null || echo '[]'
}

build_site() {
    local out
    for out in proposals completed-proposals projects; do
        atomic_write "$OUTPUT_DIR/$out.json" jq -n --indent 4 --arg out "$out" \
            --slurpfile props "$WORK/props.json" --slurpfile state "$WORK/state.json" \
            --slurpfile funds "$WORK/funds.json" \
            --slurpfile ideas "$WORK/ideas.json" -f "$CCS_LIB/site.jq"
    done
}

main() {
    load_config "${1:-/etc/ccs/ccs.conf}"
    mkdir -p "$STATE_DIR" "$OUTPUT_DIR"
    IDEAS_CACHE=$STATE_DIR/ideas.cache   # lib/gitlab.sh, ideas
    DEPOSITS=$STATE_DIR/deposits.csv     # lib/wallet.sh, donation_totals
    RETIRED_DIR=$STATE_DIR/retired       # lib/wallet.sh, retired_totals (contrib/retire-wallet)

    exec 9> "$STATE_DIR/lock"
    flock -n 9 || { log "another run is still going, skipping"; exit 0; }
    WORK=$(mktemp -d)
    trap 'rm -rf "$WORK"' EXIT

    read_proposals "$PROPOSALS_DIR" > "$WORK/props.json"
    load_state
    check_wallet_addresses
    donation_totals > "$WORK/totals.tsv"
    check_known_subaddresses
    record_new_proposals
    assign_addresses
    proposal_funds > "$WORK/funds.json"
    if ! ideas > "$WORK/ideas.json"; then
        log "warning: could not fetch ideas from GitLab, keeping the previous list"
        previous_ideas > "$WORK/ideas.json"
    fi
    proposal_images || log "warning: could not update the proposals' images, keeping the ones there"
    build_site
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi

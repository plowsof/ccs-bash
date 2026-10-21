#!/usr/bin/env bash
# ccs-back.sh [CONFIG]: one run of the CCS backend. Meant to be run from cron.
#
# Reads the proposals checkout, GitLab MRs and a view-only monero-wallet-rpc,
# then writes proposals.json and complete.json for ccs-front (Jekyll).
# The only state kept between runs is STATE_DIR/proposals.tsv (+ cached QR codes).
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

# Proposals seen for the first time: remember the merged MR they came from,
# and when funding started if they are funding-required right away.
# If GitLab is down, the proposal is tried again next run.
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

# The Ideas group of the last run, used when GitLab cannot be reached.
previous_ideas() {
    jq '.[0].proposals' "$OUTPUT_DIR/proposals.json" 2> /dev/null || echo '[]'
}

build_site() {
    local out
    for out in proposals complete; do
        jq -n --indent 4 --arg out "$out" \
            --slurpfile props "$WORK/props.json" --slurpfile state "$WORK/state.json" \
            --slurpfile totals "$WORK/totals.json" --slurpfile qr "$WORK/qr.json" \
            --slurpfile ideas "$WORK/ideas.json" -f "$CCS_LIB/site.jq" |
            atomic_write "$OUTPUT_DIR/$out.json"
    done
}

main() {
    load_config "${1:-/etc/ccs/ccs.conf}"
    mkdir -p "$STATE_DIR/qr" "$OUTPUT_DIR"

    exec 9> "$STATE_DIR/lock"
    flock -n 9 || { log "another run is still going, skipping"; exit 0; }
    WORK=$(mktemp -d)
    trap 'rm -rf "$WORK"' EXIT

    read_proposals "$PROPOSALS_DIR" > "$WORK/props.json"
    load_state
    record_new_proposals
    check_wallet_addresses
    assign_addresses
    donation_totals > "$WORK/totals.json"
    qr_codes > "$WORK/qr.json"
    if ! ideas > "$WORK/ideas.json"; then
        log "warning: could not fetch ideas from GitLab, keeping the previous list"
        previous_ideas > "$WORK/ideas.json"
    fi
    build_site
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi

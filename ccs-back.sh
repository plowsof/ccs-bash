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
# GitLab down: tried again next run, and only once this run (a fresh install has hundreds of new
# proposals, and each lookup would wait for curl's timeout).
record_new_proposals() {
    local file layout url waiting=0
    while IFS=$'\t' read -r file layout; do
        if ((waiting)); then
            waiting=$((waiting + 1))
            continue
        fi
        if ! url=$(merged_mr_url "$file"); then
            log "warning: GitLab lookup failed for new proposal $file, retrying next run"
            waiting=1
            continue
        fi
        state_update --arg f "$file" --arg u "$url" --arg fr "$([[ $layout == fr ]] && now_utc)" \
            '.[$f] = {gitlab_url: (if $u == "" then null else $u end), funding_required_date: (if $fr == "" then null else $fr end)}'
        log "new proposal $file ${url:-(no merged MR found)}"
    done < <(jq -r --slurpfile state "$WORK/state.json" '.[] | select($state[0][.file] == null) | [.file, .layout] | @tsv' "$WORK/props.json")
    if ((waiting > 1)); then
        log "warning: and $((waiting - 1)) more new proposals, not looked up this run"
    fi
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

# A proposal's raised total never goes down from what the last run published (OUTPUT_DIR/projects.json):
# a wallet or a retired wallet's record missing, or a state row cleared by hand, would otherwise show
# less. The run stops and the site keeps its last totals. A decrease that is meant: the file
# STATE_DIR/allow-lower, for one run (it is removed then). Raised only: a donation count can drop
# when a pending tx leaves the pool.
check_never_lower() {
    local lower
    [[ -f $OUTPUT_DIR/projects.json ]] || return 0
    lower=$(jq -r --slurpfile f "$WORK/funds.json" '
        .[] | select(.filename and $f[0][.filename]) | . as $p | $f[0][.filename] as $n
        | select(($p.raised_amount | tonumber) > ($n.raised | tonumber))
        | "\(.filename): \($p.raised_amount) before, \($n.raised) now"' "$OUTPUT_DIR/projects.json") || return 1
    if [[ -z $lower ]]; then
        # (not needed this run: gone all the same, or it would let a later drop through unseen)
        [[ ! -f $STATE_DIR/allow-lower ]] || { log "allow-lower: no total went down, removed"; rm -f "$STATE_DIR/allow-lower"; }
        return 0
    fi
    if [[ -f $STATE_DIR/allow-lower ]]; then
        log "warning: allow-lower: lower totals published this once: ${lower//$'\n'/; }"
        rm -f "$STATE_DIR/allow-lower"
        return 0
    fi
    die "would show less raised than before ($(grep -c . <<<"$lower") proposals: ${lower//$'\n'/; }): a wallet or a retired wallet's record missing? The site keeps its last totals (docs/troubleshooting.md)"
}

# stop_under PID SKIP: TERM every process under PID but SKIP and what is under it: the whole
# tree read first, then parents before their children, so none starts another child in between
# (read from /proc: the image has no pkill)
stop_under() {
    local f s p pp tree=() todo=("$1") at
    local -A kids=()
    for f in /proc/[0-9]*/stat; do
        s=$(< "$f") 2> /dev/null || continue
        p=${s%% *} s=${s##*) } s=${s#* } pp=${s%% *}
        [[ $p != "$2" ]] && kids[$pp]+=" $p"
    done
    while ((${#todo[@]})); do
        at=${todo[0]} todo=("${todo[@]:1}")
        for p in ${kids[$at]:-}; do tree+=("$p") todo+=("$p"); done
    done
    for p in "${tree[@]}"; do kill -TERM "$p" 2> /dev/null; done
}

main() {
    load_config "${1:-/etc/ccs/ccs.conf}"
    mkdir -p "$STATE_DIR" "$OUTPUT_DIR"
    IDEAS_CACHE=$STATE_DIR/ideas.cache   # lib/gitlab.sh, ideas
    MR_CACHE=$STATE_DIR/merged-files.cache   # lib/gitlab.sh, merged_mr_url
    DEPOSITS=$STATE_DIR/deposits.csv     # lib/wallet.sh, donation_totals
    ASSIGNED=$STATE_DIR/assigned.tsv     # lib/wallet.sh, assign_addresses and donation_totals
    RETIRED_DIR=$STATE_DIR/retired       # lib/wallet.sh, retired_totals (contrib/retire-wallet)

    exec 9> "$STATE_DIR/lock"
    flock -n 9 || { log "another run is still going, skipping"; exit 0; }
    WORK=$(mktemp -d)
    # A run that hangs (a forge or wallet that never answers, a huge state) is stopped after
    # RUN_SECONDS (config, default 900), and its lock with it: the runs after it would otherwise
    # skip ("still going") for good, and the push of the last good site hide that (it goes on)
    local max=${RUN_SECONDS:-900}
    [[ $max =~ ^[1-9][0-9]{0,5}$ ]] || max=900
    trap 'exit 1' TERM
    # (the watchdog doesn't keep the lock open, takes its sleep with it when the run ends, and
    # then stops what the run waits on: bash runs its TERM trap only once that has ended)
    (exec 9>&-; sleep "$max" & s=$!; trap 'kill "$s" 2> /dev/null; exit 0' TERM
     wait "$s" || exit 0
     log "error: the run took over ${max}s: stopped"   # (here: the run may end before its trap)
     { kill -TERM $$; stop_under $$ "$BASHPID"; } 2> /dev/null) &
    WATCHDOG=$!   # (a global: the EXIT trap runs after main has returned)
    trap 'kill "${WATCHDOG:-}" 2> /dev/null; rm -rf "$WORK"' EXIT

    read_proposals "$PROPOSALS_DIR" > "$WORK/props.json"
    load_state
    check_wallet_addresses
    donation_totals > "$WORK/totals.tsv"
    check_known_subaddresses
    record_new_proposals
    assign_addresses
    proposal_funds > "$WORK/funds.json"
    check_never_lower
    # STATE_DIR/forge-ok: when GitLab last answered (ccs-watch --run alerts when that's long ago)
    if ideas > "$WORK/ideas.json"; then
        touch "$STATE_DIR/forge-ok"
    else
        log "warning: could not fetch ideas from GitLab, keeping the previous list"
        previous_ideas > "$WORK/ideas.json"
    fi
    proposal_images || log "warning: could not update the proposals' images, keeping the ones there"
    build_site
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi

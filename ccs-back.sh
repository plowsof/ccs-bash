#!/usr/bin/env bash
# ccs-back.sh [CONFIG]: one run.
# Reads the proposals, GitLab and a view-only wallet. Writes JSON into OUTPUT_DIR.
# STATE_DIR/proposals.csv is the only real state: nothing can rebuild it.
# The other files in STATE_DIR are caches. Delete one and the next run rebuilds it.
# deposits.csv holds deposits 30 blocks deep, so each run asks the wallet only for newer ones.
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
# shellcheck source=lib/mirror.sh
source "$CCS_LIB/mirror.sh"
# shellcheck source=lib/site-data.sh
source "$CCS_LIB/site-data.sh"

# Record each new proposal: its merged MR, and its funding start date if it is in Funding Required.
# If GitLab fails, stop looking up for this run and try again next run.
# (A fresh install has hundreds of new proposals. Each failed lookup waits for curl's timeout.)
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

# record_funded: set funded_date when a Funding Required proposal first reaches its goal.
# The feed shows this date as "fully funded". It is set once and never changed.
# A proposal that was already funded when first seen gets no date.
record_funded() {
    local new
    new=$(jq -c --slurpfile funds "$WORK/funds.json" --slurpfile state "$WORK/state.json" \
        '[.[] | select(.layout == "fr" and $state[0][.file] != null and $state[0][.file].funded_date == null
            and ($funds[0][.file].percentage // 0) == 100) | .file]' "$WORK/props.json")
    [[ $new != '[]' ]] || return 0
    state_update --argjson new "$new" --arg now "$(now_utc)" 'reduce $new[] as $f (.; .[$f].funded_date = $now)'
    log "fully funded: $(jq -r 'join(", ")' <<<"$new")"
}

# GitLab is down: reuse the last run's ideas.
previous_ideas() {
    jq '.[0].proposals' "$OUTPUT_DIR/proposals.json" 2> /dev/null || echo '[]'
}

build_site() {
    site_json
    # site-data.json holds what only this run knows: each proposal's subaddress index, MR link,
    # dates and funds, plus the ideas. It holds no addresses: those come from the signed list.
    # The web server reads the front matter from the repository itself.
    # The web server checks this file and builds the site from it.
    atomic_write "$OUTPUT_DIR/site-data.json" jq -n --indent 4 \
        --slurpfile props "$WORK/props.json" --slurpfile state "$WORK/state.json" \
        --slurpfile funds "$WORK/funds.json" --slurpfile ideas "$WORK/ideas.json" '
        ($props[0] | map(.file)) as $files
        | {state: ($state[0] | with_entries(select(.key as $k | $files | index($k)))
                   | map_values({gitlab_url, subaddr_index, funding_required_date, funded_date: (.funded_date // null)})),
           funds: ($funds[0] | with_entries(select(.key as $k | $files | index($k)))),
           ideas: $ideas[0]}'
}

# A proposal's raised total must never go down from the last run's (OUTPUT_DIR/projects.json).
# A drop usually means a missing wallet, a missing retired wallet record, or a state row cleared
# by hand. Then the run stops and the site keeps its last totals.
# To allow a real drop for one run, create STATE_DIR/allow-lower. The run removes it.
# Only the raised amount is checked. The donation count can drop when a pending tx leaves the pool.
check_never_lower() {
    local lower
    [[ -f $OUTPUT_DIR/projects.json ]] || return 0
    lower=$(jq -r --slurpfile f "$WORK/funds.json" '
        .[] | select(.filename and $f[0][.filename]) | . as $p | $f[0][.filename] as $n
        | select(($p.raised_amount | tonumber) > ($n.raised | tonumber))
        | "\(.filename): \($p.raised_amount) before, \($n.raised) now"' "$OUTPUT_DIR/projects.json") || return 1
    if [[ -z $lower ]]; then
        # Not needed this run. Remove it anyway, so it can't let a later drop through.
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

# stop_under PID SKIP: send TERM to every process under PID, except SKIP and its children.
# Read the whole tree first, then stop parents before children, so none can start a new child.
# Reads /proc because the image has no pkill.
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
    HISTORIC=$STATE_DIR/historic.tsv     # lib/mirror.sh: a mirror's totals from MIRROR_URL

    exec 9> "$STATE_DIR/lock"
    flock -n 9 || { log "another run is still going, skipping"; exit 0; }
    WORK=$(mktemp -d)
    # Stop a run that hangs after RUN_SECONDS (default 900), for example a forge or wallet that
    # never answers. Otherwise it keeps the lock, every later run skips, and nobody notices
    # because the push keeps sending the last good site.
    local max=${RUN_SECONDS:-900}
    [[ $max =~ ^[1-9][0-9]{0,5}$ ]] || max=900
    trap 'exit 1' TERM
    # The watchdog closes the lock and kills its sleep when the run ends.
    # On timeout it also stops what the run is waiting on.
    # Bash runs the TERM trap only after that ends.
    (exec 9>&-; sleep "$max" & s=$!; trap 'kill "$s" 2> /dev/null; exit 0' TERM
     wait "$s" || exit 0
     log "error: the run took over ${max}s: stopped"   # logged here: the run may end before its trap runs
     { kill -TERM $$; stop_under $$ "$BASHPID"; } 2> /dev/null) &
    WATCHDOG=$!   # global: the EXIT trap runs after main returns
    trap 'kill "${WATCHDOG:-}" 2> /dev/null; rm -rf "$WORK"' EXIT

    read_proposals "$PROPOSALS_DIR" > "$WORK/props.json"
    load_state
    check_wallet_addresses
    donation_totals > "$WORK/totals.tsv"
    check_known_subaddresses
    record_new_proposals
    if [[ ${MIRROR_URL:-} ]]; then
        # Mirror mode: use the other site's addresses, never our own (lib/mirror.sh).
        # If its feed doesn't answer, keep the addresses and history from before.
        if mirror_load; then mirror_assign; else log "warning: MIRROR_URL not answering: no new addresses this run"; fi
        mirror_hide
    else
        assign_addresses
    fi
    proposal_funds > "$WORK/funds.json"
    check_never_lower
    record_funded
    # forge-ok records when GitLab last answered. ccs-watch alerts when that was too long ago.
    if ideas > "$WORK/ideas.json"; then
        touch "$STATE_DIR/forge-ok"
    else
        log "warning: could not fetch ideas from GitLab, keeping the previous list"
        previous_ideas > "$WORK/ideas.json"
    fi
    build_site
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi

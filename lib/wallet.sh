# shellcheck shell=bash
# monero-wallet-rpc (view-only wallet): subaddresses for proposals and donation totals.
# Everything uses account 0. Functions return non-zero on failure, see gitlab.sh.

# rpc METHOD [PARAMS_JSON]: print the "result" of a JSON-RPC call.
# The login is passed in a curl config on a pipe, so it never shows in `ps`.
# Digest auth is set only with a login; otherwise curl would send an empty probe.
rpc() {
    local body res
    body=$(jq -nc --arg m "$1" --argjson p "${2:-"{}"}" '{jsonrpc: "2.0", id: "0", method: $m, params: $p}') || return 1
    res=$(curl -fsS --max-time 60 \
        -K <([[ -z $RPC_USER ]] || printf 'digest\nuser = "%s:%s"\n' "$RPC_USER" "$RPC_PASSWORD") \
        -H 'Content-Type: application/json' -d "$body" "$RPC_URL") || return 1
    # RPC_QUOTE=1: turn every "amount" into a string before jq reads it, to keep all digits.
    # jq's doubles can't hold amounts above 2^53 (9007.2 XMR). One such donation would stop every run.
    [[ -z ${RPC_QUOTE:-} ]] || res=$(sed -E 's/"amount": *([0-9]+)/"amount": "\1"/g' <<<"$res") || return 1
    jq -e '.result // error("rpc '"$1"': \(.error.message // "no result")")' <<<"$res"
}

# Check this is the right wallet. Its main address must be WALLET_ADDRESS, from root's config
# (ccs-bash can write the state file but not the config). Every subaddress in the state must match.
# A restored wallet only knows index 0, so create the missing ones. A different wallet stops the run.
check_wallet_addresses() {
    local max have addrs
    max=$(jq '[.[].subaddr_index | numbers] | max // 0' "$WORK/state.json")
    addrs=$(rpc get_address '{"account_index": 0}') || return 1
    [[ $(jq -r .address <<<"$addrs") == "$WALLET_ADDRESS" ]] \
        || die "the wallet's main address is not WALLET_ADDRESS from the config (wrong wallet?)"
    have=$(jq '.addresses | length' <<<"$addrs")
    # A damaged or forged state with a huge index would create subaddresses one by one for days.
    # No signed list comes near this limit.
    ((max <= 100000)) || die "proposals.csv has subaddress index $max, past any signed list (100000): a damaged state file? (restore it)"
    while ((have <= max)); do
        rpc create_address '{"account_index": 0}' > /dev/null || return 1
        have=$((have + 1))
    done
    addrs=$(rpc get_address '{"account_index": 0}') || return 1
    jq -e --slurpfile state "$WORK/state.json" '
        (.addresses | map({key: (.address_index | tostring), value: .address}) | from_entries) as $wallet
        | [$state[0] | to_entries[] | select(.value.address)
           | select($wallet[.value.subaddr_index | tostring] != .value.address)] | length == 0' <<<"$addrs" > /dev/null \
        || die "wallet subaddresses do not match $STATE_DIR/proposals.csv (wrong wallet?)"
    # Each subaddress must belong to the proposal named in its wallet label (assign_addresses
    # sets the label to the file name). A state with two proposals' subaddresses swapped passes
    # the check above, but would show each proposal the other's address and donations.
    local swapped
    swapped=$(jq -r --slurpfile state "$WORK/state.json" '
        (.addresses | map({key: (.address_index | tostring), value: (.label // "")}) | from_entries) as $labels
        | [$state[0] | to_entries[] | select(.value.subaddr_index != null)
           | ($labels[.value.subaddr_index | tostring] // "") as $l | select($l != "" and $l != .key)
           | "\(.value.subaddr_index) (labelled \($l), given to \(.key))"] | join(", ")' <<<"$addrs") || return 1
    [[ -z $swapped ]] || die "subaddresses given to another proposal than the wallet's label says: $swapped (swapped or edited $STATE_DIR/proposals.csv? a renamed proposal: label_address it with its new file, docs/troubleshooting.md)"
    # Label any unlabelled subaddress with its proposal's file, as assign_addresses does for new ones.
    # Wallets from the old ccs-back, or restored ones, have no labels.
    # check_known_subaddresses relies on labels to tell which subaddresses were handed out.
    jq -r --slurpfile state "$WORK/state.json" '
        (.addresses | map({key: (.address_index | tostring), value: (.label // "")}) | from_entries) as $labels
        | $state[0] | to_entries[] | select(.value.subaddr_index != null and ($labels[.value.subaddr_index | tostring] // "") == "")
        | [.value.subaddr_index, .key] | @tsv' <<<"$addrs" | while IFS=$'\t' read -r idx file; do
            rpc label_address "$(jq -nc --argjson i "$idx" --arg l "$file" '{index: {major: 0, minor: $i}, label: $l}')" > /dev/null || exit 1
        done || return 1
}

# Give a new subaddress to every Funding Required proposal without one. Runs after
# check_wallet_addresses. Uses the index after the state's highest, not create_address's next.
# Why: the list publishes every address, so anyone can send to one. A donation to a subaddress
# past the last created one makes the wallet treat all up to it as created. Then create_address
# would skip ahead, and a dust payment to the list's last address would use up the whole list.
# An existing subaddress is reused if it has no label, since that means it was never handed out.
assign_addresses() {
    local file res idx addr max n
    while IFS= read -r file; do
        max=$(jq '[.[].subaddr_index | numbers] | max // 0' "$WORK/state.json")
        idx=$((max + 1))
        n=$(rpc get_address '{"account_index": 0}' | jq '.addresses | length') || return 1
        if ((idx < n)); then
            res=$(rpc get_address "{\"account_index\": 0, \"address_index\": [$idx]}") || return 1
            [[ $(jq -r '.addresses[0].label // ""' <<<"$res") == "" ]] \
                || die "subaddress $idx has a label already: handed out to a proposal $STATE_DIR/proposals.csv doesn't have (lost or wrong state file?)"
            addr=$(jq -r '.addresses[0].address' <<<"$res")
            rpc label_address "$(jq -nc --argjson i "$idx" --arg l "$file" '{index: {major: 0, minor: $i}, label: $l}')" > /dev/null || return 1
        else
            res=$(rpc create_address "$(jq -nc --arg l "$file" '{account_index: 0, label: $l}')") || return 1
            idx=$(jq -r .address_index <<<"$res")
            addr=$(jq -r .address <<<"$res")
            [[ $idx =~ ^$NUM$ ]] || die "unexpected create_address result: $res"
            # Must be just above every index in the state, or two proposals could share an address.
            ((idx == max + 1)) || die "create_address gave subaddress $idx, but the state already goes up to $max"
        fi
        [[ $addr =~ ^[0-9A-Za-z]{95}$ ]] || die "unexpected address for subaddress $idx: $res"
        state_update --arg f "$file" --argjson i "$idx" --arg a "$addr" '.[$f] += {subaddr_index: $i, address: $a}'
        log "$file: subaddress $idx $addr"
        # Deposits that arrived before the subaddress was handed out don't belong to this proposal.
        # (The next address is public on the list, so anyone can send dust to it early.)
        # Drop them from this run's totals, and record "index<TAB>height" in ASSIGNED so later
        # runs skip deposits up to that height too.
        # Record it for every subaddress handed out, even with no deposits in this run's totals:
        # those totals miss time-locked deposits, and deposits past the wallet's created range
        # (a wallet made from keys still scans 200 ahead, whatever set_subaddress_lookahead says).
        # The height is the last block's (get_height returns one more), so a donation in the next
        # block counts for the proposal.
        if [[ -n ${ASSIGNED:-} ]]; then
            local h
            h=$(rpc get_height | jq -r .height) || return 1
            [[ $h =~ ^$NUM$ && $h != 0 ]] || die "unexpected get_height result: '$h'"
            printf '%s\t%s\n' "$idx" "$((h - 1))" >> "$ASSIGNED"
            if grep -q "^$idx"$'\t' "$WORK/totals.tsv"; then
                log "warning: subaddress $idx had $(awk -F'\t' -v i="$idx" '$1 == i { print $4 }' "$WORK/totals.tsv") deposit(s) before $file was given it (sent to an address the list publishes): not counted"
                awk -F'\t' -v i="$idx" '$1 != i' "$WORK/totals.tsv" > "$WORK/totals.tmp" && mv "$WORK/totals.tmp" "$WORK/totals.tsv"
            fi
        fi
    done < <(jq -r --slurpfile state "$WORK/state.json" '
        .[] | select(.layout == "fr") | .file | select($state[0][.] and $state[0][.].address == null)' "$WORK/props.json")
}

# Money is added and converted only in bash, as 64-bit atomic units. Exact up to 9.2M XMR.
# jq's doubles round sums above ~9007 XMR and turn /1e12 into 1.23449999...

# Pattern for numbers from the state or the wallet, checked before bash arithmetic.
# No leading zero: bash reads 010 as octal 8, and 09 is an error.
# At most 18 digits: bash wraps at 2^63, so a "checked" time of 2^64 + now would read as now
# and skip the recount for good.
NUM='(0|[1-9][0-9]{0,17})'

# Atomic units -> XMR, truncated (not rounded) to 4 decimals, so never more than is there.
# 99999960000000 -> 99.9999.
xmr4() {
    printf '%d.%04d' $(($1 / 1000000000000)) $(($1 % 1000000000000 / 100000000))
}

# Same without trailing zeros (14.0000 -> 14), for JSON numbers.
# This is the only form that jq 1.6 and 1.7 print the same way.
xmr4_number() {
    local x
    x=$(xmr4 "$1")
    while [[ $x == *.*0 ]]; do x=${x%0}; done
    printf '%s' "${x%.}"
}

# XMR as written in a proposal ("240.12021", "85") -> atomic units, converted from the text.
to_atomic() {
    local whole=${1%%.*} frac=
    [[ $1 == *.* ]] && frac=${1#*.}
    frac=${frac}000000000000
    printf '%d' $((10#$whole * 1000000000000 + 10#${frac:0:12}))
}

# Print donations per subaddress in atomic units: index TAB confirmed TAB pending TAB count.
# Confirmed means at least MIN_CONFIRMATIONS; anything newer, or in the pool, is pending.
# A time-locked deposit counts only once its lock has passed. The lock is a block height
# if below 500,000,000, otherwise a unix time.
#
# Deposits are cached in STATE_DIR/deposits.csv (DEPOSITS). If deleted, the next run rebuilds it.
# A deposit is cached once its block is DEPOSITS_FINAL deep (30, and at least MIN_CONFIRMATIONS).
# Each run then asks the wallet only for newer blocks and the pool. This keeps runs fast however
# many donations there are (anyone can send dust).
#   # final <height> checked <unix time>
#   <height>,<txid>,<subaddress>,<amount>,<unlock_time>       one line per (tx, subaddress), atomic units
# Once a day, or with no file, everything is fetched and compared. Deposits the wallet has but the
# file lacks are added. Deposits the file has but the wallet lacks stop the run: a deep reorg or a
# rescanning wallet. The site then keeps its last totals. A wallet below the file's height
# (rescanning, restored) also stops the run, so a total never drops below what was once known.
donation_totals() {
    local file=${DEPOSITS:-} n indexes wh depth final kept='' H=0 T=0 now full=1 params transfers new=''
    local kind height txid idx amount unlock confs i h
    local -A confirmed=() pending=() count=() since=()
    # Subaddresses handed out after deposits reached them: deposits up to that height don't count.
    if [[ -n ${ASSIGNED:-} && -s $ASSIGNED ]]; then
        while IFS=$'\t' read -r i h; do
            [[ $i =~ ^$NUM$ && $h =~ ^$NUM$ ]] || die "$ASSIGNED: a line that isn't 'index<TAB>height' (delete it: deposits from before a subaddress was handed out then count)"
            since[$i]=$h
        done < "$ASSIGNED"
    fi
    # Subaddresses 1 and up only. Index 0 receives other things (payout change looks incoming).
    n=$(rpc get_address '{"account_index": 0}' | jq '.addresses | length') || return 1
    ((n > 1)) || return 0
    indexes=$(jq -nc --argjson n "$n" '[range(1; $n)]')
    wh=$(rpc get_height | jq -r .height) || return 1
    [[ $wh =~ ^$NUM$ ]] || die "unexpected get_height result: '$wh'"
    depth=${DEPOSITS_FINAL:-30}
    [[ $depth =~ ^[0-9]+$ ]] || depth=30
    ((depth >= MIN_CONFIRMATIONS)) || depth=$MIN_CONFIRMATIONS
    final=$((wh > depth ? wh - depth : 0))
    now=$(date +%s)
    if [[ -n $file && -s $file ]]; then
        read -r _ _ H _ T < "$file" || true
        local first=''
        IFS= read -r first < "$file" || true
        [[ $first =~ ^#\ final\ $NUM\ checked\ $NUM$ ]] || die "$file: not a deposits file (delete it: the next run makes it again)"
        kept=$(awk 'NR > 1' "$file")
        if [[ -n $kept ]] && grep -qvE "^$NUM,[0-9a-f]{64},$NUM,$NUM,$NUM\$" <<<"$kept"; then
            die "$file: a line that isn't a deposit (delete it: the next run makes it again)"
        fi
        ((wh >= H)) || die "the wallet is at height $wh, below the $H its kept deposits go to: rescanning or restored? (the site keeps its last totals until it has caught up)"
        # A "checked" time in the future (bad clock, forged file) would skip the recount forever.
        # Do a full recount instead.
        ((T <= now && now - T < 86400)) && full=''
        ((T <= now)) || log "warning: $file was checked in the future ($T): a full recount"
    fi
    if [[ $full ]]; then
        params="{\"in\": true, \"pool\": true, \"account_index\": 0, \"subaddr_indices\": $indexes}"
    else
        params="{\"in\": true, \"pool\": true, \"account_index\": 0, \"subaddr_indices\": $indexes, \"filter_by_height\": true, \"min_height\": $H}"
    fi
    transfers=$(RPC_QUOTE=1 rpc get_transfers "$params") || return 1
    # One line per transfer: kind height txid subaddress amount unlock_time confirmations.
    # jq passes amounts through as strings (RPC_QUOTE); they are checked as numbers below.
    # Anyone can send an unlock_time up to 2^64 - 1 (locked forever). One over 18 digits becomes
    # the largest 18-digit value: still locked. Otherwise bash would wrap it negative (unlocked).
    transfers=$(jq -r '
        ((.in // []) | map(. + {kind: "in"})) + ((.pool // []) | map(. + {kind: "pool"}))
        | unique_by([.txid, .subaddr_index.minor])
        | .[]
        | if (.amount | type) == "string" or .amount <= 9007199254740992 then . else error("amount \(.amount) is too large for jq to read exactly") end
        | "\(.kind) \(.height // 0) \(.txid) \(.subaddr_index.minor) \(.amount) \(if (.unlock_time // 0) >= 1e18 then "999999999999999999" else (.unlock_time // 0) end) \(.confirmations // 0)"' <<<"$transfers") || return 1
    # Check every field before bash arithmetic (an array subscript can run commands),
    # and check the txid before it goes into the file.
    while read -r kind height txid idx amount unlock confs; do
        [[ -n $kind ]] || continue
        [[ $kind =~ ^(in|pool)$ && $height =~ ^$NUM$ && $txid =~ ^[0-9a-f]{64}$ && $idx =~ ^$NUM$ && $amount =~ ^$NUM$ \
            && $unlock =~ ^$NUM$ && $confs =~ ^$NUM$ ]] \
            || die "unexpected transfer from wallet: '$kind $height $txid $idx $amount $unlock $confs'"
    done <<<"$transfers"
    if [[ $full && -n $kept ]]; then
        # Full compare up to the file's height: the wallet must know every cached deposit.
        local wallet missing extra
        wallet=$(awk -v h="$H" '$1 == "in" && $2 > 0 && $2 <= h { print $2 "," $3 "," $4 "," $5 "," $6 }' <<<"$transfers")
        missing=$(only_in "$kept" "$wallet" | grep -c . || true)
        ((missing == 0)) || die "the wallet lacks $missing of the deposits kept in $file: a reorg deeper than $depth blocks, or a wallet rescanning; check, then delete $file to make it again from the wallet"
        extra=$(only_in "$wallet" "$kept")
        if [[ -n $extra ]]; then
            log "warning: the wallet knows $(grep -c . <<<"$extra") deposit(s) below height $H that $file lacked: added"
            kept=$(printf '%s\n%s\n' "$kept" "$extra" | sort_deposits)
        fi
    fi
    # Add deposits that are now final to the file, and raise its height to final.
    new=$(awk -v lo="$H" -v hi="$final" -v full="$full" '$1 == "in" && $2 > 0 && $2 <= hi && (full != "" ? $2 > 0 : $2 > lo) { print $2 "," $3 "," $4 "," $5 "," $6 }' <<<"$transfers")
    [[ $full && -n $kept ]] && new=$(awk -F, -v h="$H" '$1 > h' <<<"$new")   # those up to H were handled by the compare above
    if [[ -n $file ]]; then
        local all
        all=$(printf '%s\n%s\n' "$kept" "$new" | sort_deposits)
        ((final > H)) || final=$H
        atomic_write "$file" printf '# final %s checked %s\n%s' "$final" "$([[ $full ]] && echo "$now" || echo "$T")" "${all:+$all$'\n'}" || return 1
        kept=$all
    else
        kept=$(printf '%s\n%s\n' "$kept" "$new" | grep . || true)
    fi
    # Totals: the cached deposits, then the ones not final yet, and the pool.
    while IFS=, read -r height txid idx amount unlock; do
        [[ -n $height ]] || continue
        [[ $height =~ ^$NUM$ && $txid =~ ^[0-9a-f]{64}$ && $idx =~ ^$NUM$ && $amount =~ ^$NUM$ && $unlock =~ ^$NUM$ ]] \
            || die "$file: a line that isn't a deposit (delete it: the next run makes it again)"
        [[ -n ${since[$idx]:-} ]] && ((height <= since[$idx])) && continue
        locked "$unlock" && continue
        confirmed[$idx]=$((${confirmed[$idx]:-0} + amount))
        count[$idx]=$((${count[$idx]:-0} + 1))
    done <<<"$kept"
    while read -r kind height txid idx amount unlock confs; do
        [[ -n $kind ]] || continue
        if [[ $kind == in ]] && ((height > 0 && height <= final)); then continue; fi   # cached, counted above
        [[ -n ${since[$idx]:-} ]] && ((height > 0 && height <= since[$idx])) && continue
        locked "$unlock" && continue
        if ((confs >= MIN_CONFIRMATIONS)); then
            confirmed[$idx]=$((${confirmed[$idx]:-0} + amount))
        else
            pending[$idx]=$((${pending[$idx]:-0} + amount))
        fi
        count[$idx]=$((${count[$idx]:-0} + 1))
    done <<<"$transfers"
    for idx in "${!count[@]}"; do
        printf '%s\t%s\t%s\t%s\n' "$idx" "${confirmed[$idx]:-0}" "${pending[$idx]:-0}" "${count[$idx]}"
    done
}

# only_in A B: print the lines of A that are not in B. (The image has no comm or sort.)
only_in() {
    awk 'NR == FNR { b[$0] = 1; next } $0 != "" && !($0 in b)' <(printf '%s\n' "$2") <(printf '%s\n' "$1")
}

# Sort deposit lines on stdin by height, txid, subaddress, without duplicates.
# Uses jq because the image has no sort. Amounts stay text.
sort_deposits() {
    jq -R -r -s 'split("\n") | map(select(. != "")) | unique
        | sort_by(split(",") | [(.[0] | tonumber), .[1], (.[2] | tonumber)]) | .[]'
}

# locked UNLOCK_TIME: true if still time-locked. Below 500,000,000 it is a block height, else a
# unix time. Compares with the wallet height wh and the time now, both set by donation_totals.
locked() {
    (($1 == 0)) && return 1
    if (($1 < 500000000)); then ((wh < $1)); else ((now < $1)); fi
}

# Stop if a subaddress that was handed out has donations but is missing from the state.
# (Handed out means it has a label: assign_addresses labels each with its file.)
# That means the state was lost, emptied or swapped, and going on would hand out new addresses.
# Runs before new addresses are made.
# A subaddress with no label was never handed out. The signed list publishes it, so anyone can
# send to it, and that must not stop every run. It is logged and counted for no proposal.
check_known_subaddresses() {
    local unknown labelled
    unknown=$(cut -f1 "$WORK/totals.tsv" | jq -c -R -s --slurpfile state "$WORK/state.json" '
        ([$state[0][] | .subaddr_index | numbers | tostring]) as $known
        | split("\n") | map(select(. != "" and (IN($known[]) | not)) | tonumber)') || return 1
    [[ $unknown != '[]' ]] || return 0
    labelled=$(rpc get_address "{\"account_index\": 0, \"address_index\": $unknown}" \
        | jq -r '[.addresses[] | select((.label // "") != "") | .address_index] | join(" ")') || return 1
    # In mirror mode the state comes from the other site's feed, and may not match every
    # proposal. The labels are that site's, so this is a warning, not a lost state file.
    if [[ $labelled && ${MIRROR_URL:-} ]]; then
        log "warning: donations at subaddress $labelled, which this wallet gave a proposal that MIRROR_URL matches none of here: not shown"
        return 0
    fi
    [[ -z $labelled ]] || die "donations at subaddress $labelled, which this wallet gave a proposal but $STATE_DIR/proposals.csv doesn't have (lost or wrong state file?)"
    log "warning: donations at subaddress $(jq -r 'join(" ")' <<<"$unknown"), which no proposal was given (no label): someone sent to an address of the wallet's that isn't on the site; not counted"
}

# Print each proposal's donations to wallets the CCS used before this one:
# file TAB atomic units TAB count.
# Read from RETIRED_DIR (STATE_DIR/retired), one file per retired wallet. contrib/retire-wallet
# writes each file once. Edit by hand only to rename a proposal. It is state, so back it up:
# the old wallet may be gone.
#   # retired <name> wallet <main address, or ccs-back-database> height <h> time <unix time>
#   <height>,<txid>,<subaddress>,<amount>,<unlock_time>,<proposal file>
# It holds no addresses, so nothing in it can reach a page.
# A deposit still time-locked at retirement counts once its lock passes. A height lock is turned
# into a time at two minutes per block, since the old wallet isn't asked again.
# Every field is checked before bash arithmetic.
retired_totals() {
    local f head w h t height txid idx amount unlock file now est n=$NUM
    local -A sum=() cnt=() seen=()
    [[ -d ${RETIRED_DIR:-} ]] || return 0
    now=$(date +%s)
    for f in "$RETIRED_DIR"/*.csv; do
        [[ -f $f ]] || continue
        head=''
        IFS= read -r head < "$f" || true
        [[ $head =~ ^#\ retired\ [a-z0-9-]+\ wallet\ ([0-9A-Za-z]{95}|ccs-back-database)\ height\ $n\ time\ $n$ ]] \
            || die "$f: not a retired wallet's file (restore it from the backup machine)"
        w=${BASH_REMATCH[1]} h=${BASH_REMATCH[2]} t=${BASH_REMATCH[3]}
        while IFS=, read -r height txid idx amount unlock file; do
            # Numbers must match NUM: no leading zero, at most 18 digits.
            [[ $height =~ ^$n$ && $txid =~ ^[0-9a-f]{64}$ && $idx =~ ^$n$ && $amount =~ ^$n$ \
                && $unlock =~ ^$n$ && $file == *.md && $file != */* && $file != *[[:cntrl:]]* \
                && ! $file =~ [1-9A-HJ-NP-Za-km-z]{90} ]] \
                || die "$f: a line that isn't a deposit (restore it from the backup machine)"
            if ((unlock != 0)); then
                if ((unlock < 500000000)); then est=$((t + (unlock > h ? unlock - h : 0) * 120)); else est=$unlock; fi
                ((now >= est)) || continue
            fi
            # Count a deposit once, even if two records of one wallet have it (retire-wallet --again).
            [[ ! ${seen[$w,$txid,$idx]:-} ]] || continue
            seen[$w,$txid,$idx]=1
            sum[$file]=$((${sum[$file]:-0} + amount))
            cnt[$file]=$((${cnt[$file]:-0} + 1))
        done < <(awk 'NR > 1' "$f")
    done
    for file in "${!sum[@]}"; do printf '%s\t%s\t%s\n' "$file" "${sum[$file]}" "${cnt[$file]}"; done
}

# Print {"file.md": {amount, raised, pending, count, percentage, needed}}, ready to display.
# amount and raised are "0.0000" strings. pending is a number (ccs-front compares it with 0).
# percentage is rounded down, so 100% means the goal was really reached.
proposal_funds() {
    local idx c p n file amount target raised pct need
    local -A conf=() pend=() cnt=() rconf=() rcnt=() hconf=() hcnt=()
    while IFS=$'\t' read -r idx c p n; do
        conf[$idx]=$c pend[$idx]=$p cnt[$idx]=$n
    done < "$WORK/totals.tsv"
    # Donations to earlier CCS wallets, per proposal file
    retired_totals > "$WORK/retired.tsv" || return 1
    while IFS=$'\t' read -r file c n; do
        rconf[$file]=$c rcnt[$file]=$n
    done < "$WORK/retired.tsv"
    # Mirror mode: the other site's totals for proposals this wallet can't see (lib/mirror.sh)
    while IFS=$'\t' read -r file c n; do
        hconf[$file]=$c hcnt[$file]=$n
    done < <(historic_totals)
    jq -r --slurpfile state "$WORK/state.json" \
        '.[] | [.file, .amount, ($state[0][.file].subaddr_index // -1)] | @tsv' "$WORK/props.json" |
        while IFS=$'\t' read -r file amount idx; do
            target=$(to_atomic "$amount")
            raised=$((${conf[$idx]:-0} + ${rconf[$file]:-0} + ${hconf[$file]:-0}))
            pct=0
            ((target > 0)) && pct=$((raised * 100 / target))
            ((pct > 100)) && pct=100
            # Amount needed: the goal minus raised and pending. Rounded up to 0.0001 so that
            # sending it reaches the goal. 0 if nothing more is needed.
            need=$((target - raised - ${pend[$idx]:-0}))
            ((need > 0)) || need=0
            need=$(((need + 99999999) / 100000000 * 100000000))
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$file" "$(xmr4 "$target")" "$(xmr4 "$raised")" \
                "$(xmr4_number "${pend[$idx]:-0}")" "$((${cnt[$idx]:-0} + ${rcnt[$file]:-0} + ${hcnt[$file]:-0}))" "$pct" "$(xmr4 "$need")"
        done | jq -R -s 'split("\n") | map(select(. != "") | split("\t") | {key: .[0], value: {
            amount: .[1], raised: .[2], pending: (.[3] | tonumber), count: (.[4] | tonumber), percentage: (.[5] | tonumber), needed: .[6]
        }}) | from_entries'
}

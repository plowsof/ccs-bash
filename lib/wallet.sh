# shellcheck shell=bash
# monero-wallet-rpc (view-only wallet): subaddresses for proposals and donation totals.
# Everything uses account 0. Functions return non-zero on failure, see gitlab.sh.

# rpc METHOD [PARAMS_JSON]: print the "result" of a JSON-RPC call. The login goes through a
# curl config on a pipe (not in `ps`); digest only with a login (else an empty probe is sent).
rpc() {
    local body res
    body=$(jq -nc --arg m "$1" --argjson p "${2:-"{}"}" '{jsonrpc: "2.0", id: "0", method: $m, params: $p}') || return 1
    res=$(curl -fsS --max-time 60 \
        -K <([[ -z $RPC_USER ]] || printf 'digest\nuser = "%s:%s"\n' "$RPC_USER" "$RPC_PASSWORD") \
        -H 'Content-Type: application/json' -d "$body" "$RPC_URL") || return 1
    jq -e '.result // error("rpc '"$1"': \(.error.message // "no result")")' <<<"$res"
}

# The wallet's main address must be WALLET_ADDRESS (root's config, unlike the state file
# ccs-bash can write), and every subaddress in the state must be the one we published.
# A restored wallet only knows index 0: create the missing ones. Another wallet stops the run.
check_wallet_addresses() {
    local max have addrs
    max=$(jq '[.[].subaddr_index | numbers] | max // 0' "$WORK/state.json")
    addrs=$(rpc get_address '{"account_index": 0}') || return 1
    [[ $(jq -r .address <<<"$addrs") == "$WALLET_ADDRESS" ]] \
        || die "the wallet's main address is not WALLET_ADDRESS from the config (wrong wallet?)"
    have=$(jq '.addresses | length' <<<"$addrs")
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
    # each with its proposal's file as its label, as assign_addresses gives new ones: a wallet from
    # ccs-back, or restored, has none, and check_known_subaddresses tells handed-out ones by it
    jq -r --slurpfile state "$WORK/state.json" '
        (.addresses | map({key: (.address_index | tostring), value: (.label // "")}) | from_entries) as $labels
        | $state[0] | to_entries[] | select(.value.subaddr_index != null and ($labels[.value.subaddr_index | tostring] // "") == "")
        | [.value.subaddr_index, .key] | @tsv' <<<"$addrs" | while IFS=$'\t' read -r idx file; do
            rpc label_address "$(jq -nc --argjson i "$idx" --arg l "$file" '{index: {major: 0, minor: $i}, label: $l}')" > /dev/null || exit 1
        done || return 1
}

# A new subaddress for every fr proposal without one (after check_wallet_addresses): the one
# after the state's highest, not create_address's next. A donation to a subaddress past the last
# created one (the list publishes them all, anyone can send) makes the wallet count every one up
# to it as created, so create_address would hand out the one after it: a dust payment to the
# list's last address would use the whole list up. One already there is used if it has no label
# (assign_addresses gave it none: never handed out).
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
            [[ $idx =~ ^[0-9]+$ ]] || die "unexpected create_address result: $res"
            # just above every index in the state, or two proposals could share an address
            ((idx == max + 1)) || die "create_address gave subaddress $idx, but the state already goes up to $max"
        fi
        [[ $addr =~ ^[0-9A-Za-z]{95}$ ]] || die "unexpected address for subaddress $idx: $res"
        state_update --arg f "$file" --argjson i "$idx" --arg a "$addr" '.[$f] += {subaddr_index: $i, address: $a}'
        log "$file: subaddress $idx $addr"
    done < <(jq -r --slurpfile state "$WORK/state.json" '
        .[] | select(.layout == "fr") | .file | select($state[0][.] and $state[0][.].address == null)' "$WORK/props.json")
}

# Money is added and converted only in bash, as 64-bit atomic units: exact to 9.2M XMR.
# jq's doubles round sums above ~9007 XMR and turn /1e12 into 1.23449999...

# Atomic units -> XMR, cut (not rounded) to 4 decimals, never more than there is: 99999960000000 -> 99.9999.
xmr4() {
    printf '%d.%04d' $(($1 / 1000000000000)) $(($1 % 1000000000000 / 100000000))
}

# Same without trailing zeros (14.0000 -> 14), for JSON numbers: the only form jq 1.6 and
# 1.7 print alike.
xmr4_number() {
    local x
    x=$(xmr4 "$1")
    while [[ $x == *.*0 ]]; do x=${x%0}; done
    printf '%s' "${x%.}"
}

# XMR as written in a proposal ("240.12021", "85") -> atomic units, from the text.
to_atomic() {
    local whole=${1%%.*} frac=
    [[ $1 == *.* ]] && frac=${1#*.}
    frac=${frac}000000000000
    printf '%d' $((10#$whole * 1000000000000 + 10#${frac:0:12}))
}

# Print donations per subaddress in atomic units: index TAB confirmed TAB pending TAB count.
# Confirmed at MIN_CONFIRMATIONS, pending before (pool too). A time-locked one counts once its
# lock has passed (a block height below 500,000,000, else a time), and not at all before.
#
# The deposits are kept in STATE_DIR/deposits.csv (DEPOSITS), a cache: deleted, the next run
# makes it again from the wallet. A deposit goes in once its block is DEPOSITS_FINAL (30, and at
# least MIN_CONFIRMATIONS) deep; each run then asks the wallet only for what came after ("final")
# and the pool, so its cost doesn't grow with every donation ever made (anyone can send dust).
#   # final <height> checked <unix time>
#   <height>,<txid>,<subaddress>,<amount>,<unlock_time>       one a (tx, subaddress), atomic units
# Once a day (or with no file) everything is fetched and compared: deposits the wallet knows that
# the file lacks are added; ones the file has that the wallet lacks stop the run (a reorg deeper
# than that, or a wallet rescanning: the site keeps its last totals). A wallet below the file's
# height (rescanning, restored) stops it too: never a total lower than the wallet once knew.
donation_totals() {
    local file=${DEPOSITS:-} n indexes wh depth final kept='' H=0 T=0 now full=1 params transfers new=''
    local kind height txid idx amount unlock confs
    local -A confirmed=() pending=() count=()
    # subaddresses 1+, never 0: it receives other things (payout change looks incoming)
    n=$(rpc get_address '{"account_index": 0}' | jq '.addresses | length') || return 1
    ((n > 1)) || return 0
    indexes=$(jq -nc --argjson n "$n" '[range(1; $n)]')
    wh=$(rpc get_height | jq -r .height) || return 1
    [[ $wh =~ ^[0-9]+$ ]] || die "unexpected get_height result: '$wh'"
    depth=${DEPOSITS_FINAL:-30}
    [[ $depth =~ ^[0-9]+$ ]] || depth=30
    ((depth >= MIN_CONFIRMATIONS)) || depth=$MIN_CONFIRMATIONS
    final=$((wh > depth ? wh - depth : 0))
    now=$(date +%s)
    if [[ -n $file && -s $file ]]; then
        read -r _ _ H _ T < "$file" || true
        local first=''
        IFS= read -r first < "$file" || true
        [[ $first =~ ^#\ final\ [0-9]+\ checked\ [0-9]+$ ]] || die "$file: not a deposits file (delete it: the next run makes it again)"
        kept=$(awk 'NR > 1' "$file")
        if [[ -n $kept ]] && grep -qvE '^[0-9]+,[0-9a-f]{64},[0-9]+,[0-9]+,[0-9]+$' <<<"$kept"; then
            die "$file: a line that isn't a deposit (delete it: the next run makes it again)"
        fi
        ((wh >= H)) || die "the wallet is at height $wh, below the $H its kept deposits go to: rescanning or restored? (the site keeps its last totals until it has caught up)"
        ((now - T < 86400)) && full=''
    fi
    if [[ $full ]]; then
        params="{\"in\": true, \"pool\": true, \"account_index\": 0, \"subaddr_indices\": $indexes}"
    else
        params="{\"in\": true, \"pool\": true, \"account_index\": 0, \"subaddr_indices\": $indexes, \"filter_by_height\": true, \"min_height\": $H}"
    fi
    transfers=$(rpc get_transfers "$params") || return 1
    # kind height txid subaddress amount unlock_time confirmations; jq only passes amounts
    # through, and stops above 2^53, where it can't read them exactly
    transfers=$(jq -r '
        ((.in // []) | map(. + {kind: "in"})) + ((.pool // []) | map(. + {kind: "pool"}))
        | unique_by([.txid, .subaddr_index.minor])
        | .[]
        | if .amount > 9007199254740992 then error("amount \(.amount) is too large for jq to read exactly") else . end
        | "\(.kind) \(.height // 0) \(.txid) \(.subaddr_index.minor) \(.amount) \(.unlock_time // 0) \(.confirmations // 0)"' <<<"$transfers") || return 1
    # every field checked before bash arithmetic (a subscript can run commands), and the txid
    # before it goes in the file
    while read -r kind height txid idx amount unlock confs; do
        [[ -n $kind ]] || continue
        [[ $kind =~ ^(in|pool)$ && $height =~ ^[0-9]+$ && $txid =~ ^[0-9a-f]{64}$ && $idx =~ ^[0-9]+$ && $amount =~ ^[0-9]+$ \
            && $unlock =~ ^[0-9]+$ && $confs =~ ^[0-9]+$ ]] \
            || die "unexpected transfer from wallet: '$kind $height $txid $idx $amount $unlock $confs'"
    done <<<"$transfers"
    if [[ $full && -n $kept ]]; then
        # everything compared, up to the file's height: the wallet must know every kept deposit
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
    # deposits now final: into the file, and its height up to final
    new=$(awk -v lo="$H" -v hi="$final" -v full="$full" '$1 == "in" && $2 > 0 && $2 <= hi && (full != "" ? $2 > 0 : $2 > lo) { print $2 "," $3 "," $4 "," $5 "," $6 }' <<<"$transfers")
    [[ $full && -n $kept ]] && new=$(awk -F, -v h="$H" '$1 > h' <<<"$new")   # (those up to H were compared above)
    if [[ -n $file ]]; then
        local all
        all=$(printf '%s\n%s\n' "$kept" "$new" | sort_deposits)
        ((final > H)) || final=$H
        atomic_write "$file" printf '# final %s checked %s\n%s' "$final" "$([[ $full ]] && echo "$now" || echo "$T")" "${all:+$all$'\n'}" || return 1
        kept=$all
    else
        kept=$(printf '%s\n%s\n' "$kept" "$new" | grep . || true)
    fi
    # the totals: the kept deposits, then what isn't final yet (and the pool)
    while IFS=, read -r height txid idx amount unlock; do
        [[ -n $height ]] || continue
        [[ $height =~ ^[0-9]+$ && $txid =~ ^[0-9a-f]{64}$ && $idx =~ ^[0-9]+$ && $amount =~ ^[0-9]+$ && $unlock =~ ^[0-9]+$ ]] \
            || die "$file: a line that isn't a deposit (delete it: the next run makes it again)"
        locked "$unlock" && continue
        confirmed[$idx]=$((${confirmed[$idx]:-0} + amount))
        count[$idx]=$((${count[$idx]:-0} + 1))
    done <<<"$kept"
    while read -r kind height txid idx amount unlock confs; do
        [[ -n $kind ]] || continue
        if [[ $kind == in ]] && ((height > 0 && height <= final)); then continue; fi   # kept, counted above
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

# only_in A B: the lines of A that B lacks (the image has no comm or sort)
only_in() {
    awk 'NR == FNR { b[$0] = 1; next } $0 != "" && !($0 in b)' <(printf '%s\n' "$2") <(printf '%s\n' "$1")
}

# Deposit lines on stdin, once each, by height, txid, subaddress (jq: the image has no sort;
# the amounts stay text)
sort_deposits() {
    jq -R -r -s 'split("\n") | map(select(. != "")) | unique
        | sort_by(split(",") | [(.[0] | tonumber), .[1], (.[2] | tonumber)]) | .[]'
}

# locked UNLOCK_TIME: still time-locked (a block height below 500,000,000, else a unix time), with
# the wallet at height wh and the time now (donation_totals')
locked() {
    (($1 == 0)) && return 1
    if (($1 < 500000000)); then ((wh < $1)); else ((now < $1)); fi
}

# Stop if donations sit at a subaddress this wallet gave a proposal (assign_addresses labels each
# with its file) that the state doesn't have (lost, emptied or swapped state; going on would hand
# out new addresses). Runs before new ones are made. One with no label was never handed out: the
# signed list publishes them, so anyone can send to one, which mustn't stop every run; it is
# logged, and counted for no proposal.
check_known_subaddresses() {
    local unknown labelled
    unknown=$(cut -f1 "$WORK/totals.tsv" | jq -c -R -s --slurpfile state "$WORK/state.json" '
        ([$state[0][] | .subaddr_index | numbers | tostring]) as $known
        | split("\n") | map(select(. != "" and (IN($known[]) | not)) | tonumber)') || return 1
    [[ $unknown != '[]' ]] || return 0
    labelled=$(rpc get_address "{\"account_index\": 0, \"address_index\": $unknown}" \
        | jq -r '[.addresses[] | select((.label // "") != "") | .address_index] | join(" ")') || return 1
    [[ -z $labelled ]] || die "donations at subaddress $labelled, which this wallet gave a proposal but $STATE_DIR/proposals.csv doesn't have (lost or wrong state file?)"
    log "warning: donations at subaddress $(jq -r 'join(" ")' <<<"$unknown"), which no proposal was given (no label): someone sent to an address of the wallet's that isn't on the site; not counted"
}

# Print each proposal's donations to the wallets the CCS used before this one, file TAB atomic units
# TAB count, from RETIRED_DIR (STATE_DIR/retired), one file per retired wallet, written once by
# contrib/retire-wallet and never changed (state, backed up: the old wallet may be gone):
#   # retired <name> wallet <main address, or ccs-back-database> height <h> time <unix time>
#   <height>,<txid>,<subaddress>,<amount>,<unlock_time>,<proposal file>
# No addresses: nothing in it can reach a page. A deposit still time-locked when its wallet was
# retired counts once its lock has passed: a time, or a height taken as two minutes a block from
# then (the old wallet isn't asked again). Every field checked before bash arithmetic.
retired_totals() {
    local f head h t height txid idx amount unlock file now est
    local -A sum=() cnt=()
    [[ -d ${RETIRED_DIR:-} ]] || return 0
    now=$(date +%s)
    for f in "$RETIRED_DIR"/*.csv; do
        [[ -f $f ]] || continue
        head=''
        IFS= read -r head < "$f" || true
        [[ $head =~ ^#\ retired\ [a-z0-9-]+\ wallet\ ([0-9A-Za-z]{95}|ccs-back-database)\ height\ ([0-9]+)\ time\ ([0-9]+)$ ]] \
            || die "$f: not a retired wallet's file (restore it from the backup machine)"
        h=${BASH_REMATCH[2]} t=${BASH_REMATCH[3]}
        while IFS=, read -r height txid idx amount unlock file; do
            [[ $height =~ ^[0-9]+$ && $txid =~ ^[0-9a-f]{64}$ && $idx =~ ^[0-9]+$ && $amount =~ ^[0-9]+$ \
                && $unlock =~ ^[0-9]+$ && $file == *.md && $file != */* && $file != *[[:cntrl:]]* \
                && ! $file =~ [1-9A-HJ-NP-Za-km-z]{90} ]] \
                || die "$f: a line that isn't a deposit (restore it from the backup machine)"
            if ((unlock != 0)); then
                if ((unlock < 500000000)); then est=$((t + (unlock > h ? unlock - h : 0) * 120)); else est=$unlock; fi
                ((now >= est)) || continue
            fi
            sum[$file]=$((${sum[$file]:-0} + amount))
            cnt[$file]=$((${cnt[$file]:-0} + 1))
        done < <(awk 'NR > 1' "$f")
    done
    for file in "${!sum[@]}"; do printf '%s\t%s\t%s\n' "$file" "${sum[$file]}" "${cnt[$file]}"; done
}

# Print {"file.md": {amount, raised, pending, count, percentage}}, ready to show: amount and
# raised "0.0000" strings, pending a number (ccs-front compares it with 0), percentage
# rounded down (100% means really reached).
proposal_funds() {
    local idx c p n file amount target raised pct
    local -A conf=() pend=() cnt=() rconf=() rcnt=()
    while IFS=$'\t' read -r idx c p n; do
        conf[$idx]=$c pend[$idx]=$p cnt[$idx]=$n
    done < "$WORK/totals.tsv"
    # donations to wallets the CCS used before this one, per proposal file
    retired_totals > "$WORK/retired.tsv" || return 1
    while IFS=$'\t' read -r file c n; do
        rconf[$file]=$c rcnt[$file]=$n
    done < "$WORK/retired.tsv"
    jq -r --slurpfile state "$WORK/state.json" \
        '.[] | [.file, .amount, ($state[0][.file].subaddr_index // -1)] | @tsv' "$WORK/props.json" |
        while IFS=$'\t' read -r file amount idx; do
            target=$(to_atomic "$amount")
            raised=$((${conf[$idx]:-0} + ${rconf[$file]:-0}))
            pct=0
            ((target > 0)) && pct=$((raised * 100 / target))
            ((pct > 100)) && pct=100
            printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$file" "$(xmr4 "$target")" "$(xmr4 "$raised")" \
                "$(xmr4_number "${pend[$idx]:-0}")" "$((${cnt[$idx]:-0} + ${rcnt[$file]:-0}))" "$pct"
        done | jq -R -s 'split("\n") | map(select(. != "") | split("\t") | {key: .[0], value: {
            amount: .[1], raised: .[2], pending: (.[3] | tonumber), count: (.[4] | tonumber), percentage: (.[5] | tonumber)
        }}) | from_entries'
}

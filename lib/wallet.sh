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
    rpc get_address '{"account_index": 0}' | jq -e --slurpfile state "$WORK/state.json" '
        (.addresses | map({key: (.address_index | tostring), value: .address}) | from_entries) as $wallet
        | [$state[0] | to_entries[] | select(.value.address)
           | select($wallet[.value.subaddr_index | tostring] != .value.address)] | length == 0' > /dev/null \
        || die "wallet subaddresses do not match $STATE_DIR/proposals.csv (wrong wallet?)"
}

# A new subaddress for every fr proposal without one (after check_wallet_addresses).
assign_addresses() {
    local file res idx addr max
    while IFS= read -r file; do
        res=$(rpc create_address "$(jq -nc --arg l "$file" '{account_index: 0, label: $l}')") || return 1
        idx=$(jq -r .address_index <<<"$res")
        addr=$(jq -r .address <<<"$res")
        [[ $idx =~ ^[0-9]+$ && $addr =~ ^[0-9A-Za-z]{95}$ ]] || die "unexpected create_address result: $res"
        # above every index in the state, or two proposals could share an address
        max=$(jq '[.[].subaddr_index | numbers] | max // 0' "$WORK/state.json")
        ((idx > max)) || die "create_address gave subaddress $idx, but the state already goes up to $max"
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
# Confirmed at MIN_CONFIRMATIONS, pending before (pool too); time-locked txes never count.
donation_totals() {
    local transfers lines idx confs amount n indexes
    local -A confirmed=() pending=() count=()
    # subaddresses 1+, never 0: it receives other things (payout change looks incoming)
    n=$(rpc get_address '{"account_index": 0}' | jq '.addresses | length') || return 1
    ((n > 1)) || return 0
    indexes=$(jq -nc --argjson n "$n" '[range(1; $n)]')
    transfers=$(rpc get_transfers "{\"in\": true, \"pool\": true, \"account_index\": 0, \"subaddr_indices\": $indexes}") || return 1
    # jq only passes amounts through, and stops above 2^53, where it can't read them exactly
    lines=$(jq -r '
        (.in // []) + (.pool // [])
        | map(select((.unlock_time // 0) == 0))
        | unique_by([.txid, .subaddr_index.minor])
        | .[]
        | if .amount > 9007199254740992 then error("amount \(.amount) is too large for jq to read exactly") else . end
        | "\(.subaddr_index.minor) \(.confirmations // 0) \(.amount)"' <<<"$transfers") || return 1
    while read -r idx confs amount; do
        [[ -n $idx ]] || continue # no transfers at all
        # plain numbers only: bash arithmetic runs commands hidden in subscripts ("x[$(cmd)]")
        [[ $idx =~ ^[0-9]+$ && $confs =~ ^[0-9]+$ && $amount =~ ^[0-9]+$ ]] \
            || die "unexpected transfer from wallet: index '$idx' confirmations '$confs' amount '$amount'"
        if ((confs >= MIN_CONFIRMATIONS)); then
            confirmed[$idx]=$((${confirmed[$idx]:-0} + amount))
        else
            pending[$idx]=$((${pending[$idx]:-0} + amount))
        fi
        count[$idx]=$((${count[$idx]:-0} + 1))
    done <<<"$lines"
    for idx in "${!count[@]}"; do
        printf '%s\t%s\t%s\t%s\n' "$idx" "${confirmed[$idx]:-0}" "${pending[$idx]:-0}" "${count[$idx]}"
    done
}

# Stop if donations sit at a subaddress the state doesn't have (lost, emptied or swapped
# state; going on would hand out new addresses). Runs before new ones are made.
check_known_subaddresses() {
    local unknown
    unknown=$(cut -f1 "$WORK/totals.tsv" | jq -R -s --slurpfile state "$WORK/state.json" '
        ([$state[0][] | .subaddr_index | numbers | tostring]) as $known
        | split("\n") | map(select(. != "" and (IN($known[]) | not))) | join(" ")') || return 1
    unknown=$(jq -r . <<<"$unknown")
    [[ -z $unknown ]] || die "donations at subaddress $unknown, which $STATE_DIR/proposals.csv doesn't have (lost or wrong state file?)"
}

# Print {"file.md": {amount, raised, pending, count, percentage}}, ready to show: amount and
# raised "0.0000" strings, pending a number (ccs-front compares it with 0), percentage
# rounded down (100% means really reached).
proposal_funds() {
    local idx c p n file amount target raised pct
    local -A conf=() pend=() cnt=()
    while IFS=$'\t' read -r idx c p n; do
        conf[$idx]=$c pend[$idx]=$p cnt[$idx]=$n
    done < "$WORK/totals.tsv"
    jq -r --slurpfile state "$WORK/state.json" \
        '.[] | [.file, .amount, ($state[0][.file].subaddr_index // -1)] | @tsv' "$WORK/props.json" |
        while IFS=$'\t' read -r file amount idx; do
            target=$(to_atomic "$amount")
            raised=${conf[$idx]:-0}
            pct=0
            ((target > 0)) && pct=$((raised * 100 / target))
            ((pct > 100)) && pct=100
            printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$file" "$(xmr4 "$target")" "$(xmr4 "$raised")" \
                "$(xmr4_number "${pend[$idx]:-0}")" "${cnt[$idx]:-0}" "$pct"
        done | jq -R -s 'split("\n") | map(select(. != "") | split("\t") | {key: .[0], value: {
            amount: .[1], raised: .[2], pending: (.[3] | tonumber), count: (.[4] | tonumber), percentage: (.[5] | tonumber)
        }}) | from_entries'
}

# Print {"<index>": "<base64 png>"} for every address in the state, made fresh each run and
# never stored, so there is no image to swap.
qr_codes() {
    local idx addr
    mkdir -p "$WORK/qr"
    jq -r '.[] | select(.address) | [.subaddr_index, .address] | @tsv' "$WORK/state.json" |
        while IFS=$'\t' read -r idx addr; do
            qrencode -s 10 -o "$WORK/qr/$idx.png" "monero:$addr"
            printf '%s\t%s\n' "$idx" "$(base64 -w0 "$WORK/qr/$idx.png")"
        done | jq -R -s 'split("\n") | map(select(. != "") | split("\t") | {key: .[0], value: .[1]}) | from_entries'
}

# shellcheck shell=bash
# monero-wallet-rpc (view-only wallet): subaddresses for proposals and donation totals.
# Everything uses account 0. Functions return non-zero on failure, see gitlab.sh.

# rpc METHOD [PARAMS_JSON]: print the "result" of a JSON-RPC call.
# Credentials go through a curl config on a pipe, so they never show up in `ps`.
# Digest auth is only used with a login: without one curl would send an empty probe request.
rpc() {
    local body res
    body=$(jq -nc --arg m "$1" --argjson p "${2:-"{}"}" '{jsonrpc: "2.0", id: "0", method: $m, params: $p}') || return 1
    res=$(curl -fsS --max-time 60 \
        -K <([[ -z $RPC_USER ]] || printf 'digest\nuser = "%s:%s"\n' "$RPC_USER" "$RPC_PASSWORD") \
        -H 'Content-Type: application/json' -d "$body" "$RPC_URL") || return 1
    jq -e '.result // error("rpc '"$1"': \(.error.message // "no result")")' <<<"$res"
}

# Make sure the wallet has created every subaddress in the state file, and that
# they are the addresses we published. After restoring the wallet from keys it
# only knows index 0, so this creates the missing ones (and makes the wallet scan
# them). A different wallet fails the address check and stops the run.
#
# First of all, the wallet's main address must be WALLET_ADDRESS from the config.
# The state file is writable by ccs-bash, the config is not: with both pinned, a
# swapped wallet is caught even if the state file was changed to match it.
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

# Give every funding-required proposal without an address a new subaddress.
# Runs after check_wallet_addresses, so new indexes never reuse ones in the state.
assign_addresses() {
    local file res idx addr
    while IFS= read -r file; do
        res=$(rpc create_address "$(jq -nc --arg l "$file" '{account_index: 0, label: $l}')") || return 1
        idx=$(jq -r .address_index <<<"$res")
        addr=$(jq -r .address <<<"$res")
        [[ $idx =~ ^[0-9]+$ && $addr =~ ^[0-9A-Za-z]{95}$ ]] || die "unexpected create_address result: $res"
        state_update --arg f "$file" --argjson i "$idx" --arg a "$addr" '.[$f] += {subaddr_index: $i, address: $a}'
        log "$file: subaddress $idx $addr"
    done < <(jq -r --slurpfile state "$WORK/state.json" '
        .[] | select(.layout == "fr") | .file | select($state[0][.] and $state[0][.].address == null)' "$WORK/props.json")
}

# Money is only ever added up and converted in bash, with 64-bit integers in
# atomic units (1 XMR = 1e12), so it is exact up to 9.2 million XMR. jq has
# only doubles: it would round sums above ~9007 XMR, and dividing by 1e12 gives
# numbers like 1.23449999.. that come out a unit short when cut to 4 decimals.

# Atomic units -> XMR, cut off (not rounded) at 4 decimals: 99999960000000 -> 99.9999.
# Never shows more than there is.
xmr4() {
    printf '%d.%04d' $(($1 / 1000000000000)) $(($1 % 1000000000000 / 100000000))
}

# Same, without trailing zeros (14.0000 -> 14, 0.1200 -> 0.12), for amounts that
# go into the JSON as numbers: jq 1.7 keeps a number's text as written, jq 1.6
# does not, so only this form prints the same with both.
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

# Print donations per subaddress, in atomic units, one line each:
#   index <TAB> confirmed <TAB> pending <TAB> count
# A tx is confirmed once it has MIN_CONFIRMATIONS; until then (pool included)
# it is pending. count is every tx, pending or not.
# Time-locked txes (unlock_time set) are never counted.
donation_totals() {
    local transfers lines idx confs amount
    local -A confirmed=() pending=() count=()
    transfers=$(rpc get_transfers '{"in": true, "pool": true, "account_index": 0}') || return 1
    # jq only passes each amount through. Above 2^53 it could not even read it
    # exactly, so it stops the run instead.
    lines=$(jq -r '
        (.in // []) + (.pool // [])
        | map(select((.unlock_time // 0) == 0))
        | unique_by([.txid, .subaddr_index.minor])
        | .[]
        | if .amount > 9007199254740992 then error("amount \(.amount) is too large for jq to read exactly") else . end
        | "\(.subaddr_index.minor) \(.confirmations // 0) \(.amount)"' <<<"$transfers") || return 1
    while read -r idx confs amount; do
        [[ -n $idx ]] || continue # no transfers at all
        [[ $amount =~ ^[0-9]+$ ]] || die "unexpected amount from wallet: $amount"
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

# Print every proposal's money, ready to show: {"file.md": {amount, raised,
# pending, count, percentage}}. amount and raised are "0.0000" strings, pending
# a number (ccs-front compares it with 0). The percentage is rounded down, so
# 100% means the target was really reached.
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

# Print {"<index>": "<base64 png>"} for every address in the state. The images are
# made fresh on every run and never kept, so there is no stored image someone could
# swap for one with their own address. (CI checks qrencode with a real decoder.)
qr_codes() {
    local idx addr
    mkdir -p "$WORK/qr"
    jq -r '.[] | select(.address) | [.subaddr_index, .address] | @tsv' "$WORK/state.json" |
        while IFS=$'\t' read -r idx addr; do
            qrencode -s 10 -o "$WORK/qr/$idx.png" "monero:$addr"
            printf '%s\t%s\n' "$idx" "$(base64 -w0 "$WORK/qr/$idx.png")"
        done | jq -R -s 'split("\n") | map(select(. != "") | split("\t") | {key: .[0], value: .[1]}) | from_entries'
}

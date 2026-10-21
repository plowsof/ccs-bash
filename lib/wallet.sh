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
check_wallet_addresses() {
    local max have
    max=$(jq '[.[].subaddr_index | numbers] | max // 0' "$WORK/state.json")
    have=$(rpc get_address '{"account_index": 0}' | jq '.addresses | length') || return 1
    while ((have <= max)); do
        rpc create_address '{"account_index": 0}' > /dev/null || return 1
        have=$((have + 1))
    done
    rpc get_address '{"account_index": 0}' | jq -e --slurpfile state "$WORK/state.json" '
        (.addresses | map({key: (.address_index | tostring), value: .address}) | from_entries) as $wallet
        | [$state[0] | to_entries[] | select(.value.address)
           | select($wallet[.value.subaddr_index | tostring] != .value.address)] | length == 0' > /dev/null \
        || die "wallet subaddresses do not match $STATE_DIR/proposals.tsv (wrong wallet?)"
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

# Print confirmed donations per subaddress: {"<index>": {"atomic": N, "count": N}}.
# A tx counts once it has MIN_CONFIRMATIONS (0 = count pool txes too).
# Time-locked txes (unlock_time set) are never counted.
donation_totals() {
    rpc get_transfers '{"in": true, "pool": true, "account_index": 0}' | jq --argjson min "$MIN_CONFIRMATIONS" '
        (.in // []) + (.pool // [])
        | map(select((.confirmations // 0) >= $min and (.unlock_time // 0) == 0))
        | unique_by([.txid, .subaddr_index.minor])
        | group_by(.subaddr_index.minor)
        | map({key: (.[0].subaddr_index.minor | tostring), value: {atomic: (map(.amount) | add), count: length}})
        | from_entries'
}

# Print {"<index>": "<base64 png>"} for every address in the state.
# PNGs are made once and kept in STATE_DIR/qr.
qr_codes() {
    local idx addr png
    jq -r '.[] | select(.address) | [.subaddr_index, .address] | @tsv' "$WORK/state.json" |
        while IFS=$'\t' read -r idx addr; do
            png=$STATE_DIR/qr/$idx.png
            [[ -s $png ]] || qrencode -s 10 -o "$png" "monero:$addr"
            printf '%s\t%s\n' "$idx" "$(base64 -w0 "$png")"
        done | jq -R -s 'split("\n") | map(select(. != "") | split("\t") | {key: .[0], value: .[1]}) | from_entries'
}

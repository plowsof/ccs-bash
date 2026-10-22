# shellcheck shell=bash
# Stand-ins for the wallet, GitLab and qrencode, used by run.sh.
# Needs $TEST_TMP (scratch dir) and $FIXTURES.

# Fake wallet: freshly restored, so it starts with only subaddress 0 created.
# Subaddress N is "8" followed by N zero-padded to 94 digits.
fake_address() { printf '8%094d' "$1"; }
rpc() {
    local n i
    n=$(cat "$TEST_TMP/wallet-count")
    case $1 in
        get_address)
            for ((i = 0; i < n; i++)); do
                printf '{"address_index": %d, "address": "%s"}\n' "$i" "$(fake_address "$i")"
            done | jq -s --arg main "$(fake_address 0)" '{address: $main, addresses: .}' ;;
        create_address) # TEST_REUSE_INDEX=1: a wallet that hands out subaddress 1 again
            echo $((n + 1)) > "$TEST_TMP/wallet-count"
            [[ -z ${TEST_REUSE_INDEX:-} ]] || n=1
            printf '{"address_index": %d, "address": "%s"}\n' "$n" "$(fake_address "$n")" ;;
        get_transfers) # like the real one: only the subaddresses asked for
            jq --argjson want "$(jq -c '.subaddr_indices // []' <<<"$2")" \
                'map_values(map(select(.subaddr_index.minor | IN($want[]))))' "$FIXTURES/rpc/get_transfers.json" ;;
        *) return 1 ;;
    esac
}

gitlab_get() {
    local iid
    case $1 in
        merge_requests\?state=opened*) cat "$FIXTURES/gitlab/opened.json" ;;
        merge_requests\?state=merged*) cat "$FIXTURES/gitlab/merged.json" ;;
        merge_requests/*/changes)
            iid=${1#merge_requests/}
            [[ ${iid%/changes} != "${TEST_FAIL_MR:-}" ]] || return 1 # TEST_FAIL_MR=N: that MR fails
            cat "$FIXTURES/gitlab/changes-${iid%/changes}.json" ;;
        *) return 1 ;;
    esac
}

now_utc() { echo 2026-10-22T08:00:00Z; }

# Called as: qrencode -s 10 -o FILE URI. The "image" is just the text.
qrencode() { printf 'QR for %s' "$5" > "$4"; }

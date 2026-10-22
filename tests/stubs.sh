# shellcheck shell=bash
# Stand-ins for the wallet, GitLab, qrencode and zbarimg, used by run.sh.
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
            done | jq -s '{addresses: .}' ;;
        create_address)
            echo $((n + 1)) > "$TEST_TMP/wallet-count"
            printf '{"address_index": %d, "address": "%s"}\n' "$n" "$(fake_address "$n")" ;;
        get_transfers) cat "$FIXTURES/rpc/get_transfers.json" ;;
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
            cat "$FIXTURES/gitlab/changes-${iid%/changes}.json" ;;
        *) return 1 ;;
    esac
}

now_utc() { echo 2026-10-22T08:00:00Z; }

# Called as: qrencode -s 10 -o FILE URI. The "image" is just the text.
qrencode() { printf 'QR for %s' "$5" > "$4"; }
# Called as: zbarimg --quiet --raw FILE
zbarimg() { local qr; qr=$(cat "$3") && printf '%s\n' "${qr#QR for }"; }

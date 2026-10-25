# shellcheck shell=bash
# Stand-ins for the wallet, GitLab and qrencode, used by run.sh.
# Needs $TEST_TMP (scratch dir) and $FIXTURES.

# Fake wallet: freshly restored, so it starts with only subaddress 0 created.
# Subaddress N is "8" followed by N zero-padded to 94 digits.
fake_address() { printf '8%094d' "$1"; }
rpc() {
    local n
    n=$(cat "$TEST_TMP/wallet-count")
    case $1 in
        get_address) # all, or those address_index asks for; each with the label create_address gave it
            : >> "$TEST_TMP/wallet-labels"
            jq -n --arg p "$(fake_address 0 | cut -c1)" --argjson n "$n" --argjson want "$(jq -c '.address_index // null' <<<"${2:-"{}"}")" \
                --rawfile l "$TEST_TMP/wallet-labels" '
                ($l | split("\n") | map(select(. != "") | capture("^(?<i>[0-9]+) ?(?<l>.*)$") | {(.i): .l}) | add // {}) as $labels
                | def address: $p + (("0" * 94) + tostring)[-94:];
                {address: (0 | address), addresses: [if $want then $want[] else range(0; $n) end | select(. < $n)
                    | {address_index: ., address: address, label: ($labels[tostring] // "")}]}' ;;
        create_address) # TEST_REUSE_INDEX=1: a wallet that hands out subaddress 1 again
            echo $((n + 1)) > "$TEST_TMP/wallet-count"
            [[ -z ${TEST_REUSE_INDEX:-} ]] || n=1
            printf '%d %s\n' "$n" "$(jq -r '.label // empty' <<<"$2")" >> "$TEST_TMP/wallet-labels"
            printf '{"address_index": %d, "address": "%s"}\n' "$n" "$(fake_address "$n")" ;;
        label_address)
            jq -r '"\(.index.minor) \(.label)"' <<<"$2" >> "$TEST_TMP/wallet-labels"; echo '{}' ;;
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
        # Forgejo: the same MRs as Forgejo pull requests (times with an offset, a closed PR
        # that was not merged among the merged ones)
        pulls\?state=open*) gitlab_forgejo < "$FIXTURES/gitlab/opened.json" ;;
        pulls\?state=closed*)
            gitlab_forgejo < "$FIXTURES/gitlab/merged.json" | jq 'map(. + {merged: true})
                + [{number: 99, html_url: "https://example.org/pr/99", title: "Closed, not merged", user: {login: "x"},
                    created_at: "2026-10-01T14:00:00+02:00", merged: false}]' ;;
        issues/*/reactions*)   # the MR's votes as reactions (and a heart, not a vote); none is null
            iid=${1#issues/}; iid=${iid%%/*}
            [[ $iid != "${TEST_FAIL_VOTES:-}" ]] || return 1   # TEST_FAIL_VOTES=N: its reactions fail
            jq --argjson i "$iid" '.[] | select(.iid == $i) | [range(.upvotes) | {content: "+1"}] + [range(.downvotes) | {content: "-1"}]
                | if length == 0 then null else . + [{content: "heart"}] end' "$FIXTURES/gitlab/opened.json" ;;
        # an MR's file at its commit (sha-N: MR N's); TEST_FAIL_RAW=N: that one fails
        repository/files/*/raw\?ref=* | raw/*\?ref=*)
            [[ ${1##*ref=} != "sha-${TEST_FAIL_RAW:-}" ]] || return 1
            cat "$FIXTURES/gitlab/raw/${1##*ref=}" ;;
        pulls/*/files*)
            iid=${1#pulls/}; iid=${iid%%/*}
            [[ $iid != "${TEST_FAIL_MR:-}" ]] || return 1
            jq '.changes | map({filename: .new_path, status: (if .new_file then "added" else "changed" end)})' \
                "$FIXTURES/gitlab/changes-$iid.json" ;;
        *) return 1 ;;
    esac
}

# GitLab MRs -> Forgejo pull requests; Z times become the same moment at +14:00 (the next
# day in that zone: a wrong conversion shows the wrong date)
gitlab_forgejo() {
    jq 'map({number: .iid, html_url: .web_url, title, user: {login: .author.username}, merged: false, head: {sha: .sha},
        created_at: (.created_at | if . == null then null else sub("\\.[0-9]+Z$"; "Z") | fromdate + 50400 | todate | sub("Z$"; "+14:00") end)})'
}

now_utc() { echo 2026-10-22T08:00:00Z; }

# Called as: qrencode -s 10 -o FILE URI. The "image" is just the text.
qrencode() { printf 'QR for %s' "$5" > "$4"; }

#!/usr/bin/env bash
# End-to-end test: runs ccs-back.sh against tests/fixtures with the wallet, GitLab
# and qrencode replaced by tests/stubs.sh, then compares with tests/expected.
# UPDATE=1 tests/run.sh rewrites the expected files (check the diff!).
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
export FIXTURES=$here/fixtures TEST_TMP
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

mkdir -p "$TEST_TMP/state"
cp "$FIXTURES/state.csv" "$TEST_TMP/state/proposals.csv"
echo 1 > "$TEST_TMP/wallet-count"
cat > "$TEST_TMP/ccs.conf" <<CONF
RPC_URL=http://wallet.invalid/json_rpc
REPOSITORY_URL=https://gitlab.invalid/api/v4/projects/1
PROPOSALS_DIR=$FIXTURES/proposals
STATE_DIR=$TEST_TMP/state
OUTPUT_DIR=$TEST_TMP/out
CONF

# Two runs: the second must not create addresses or change the output.
# Each run is its own bash process so that `set -e` behaves as it does under cron.
for run in 1 2; do
    if ! bash -c 'source "$1/../ccs-back.sh" && source "$1/stubs.sh" && main "$2"' _ "$here" "$TEST_TMP/ccs.conf" \
        2> "$TEST_TMP/log-$run"; then
        cat "$TEST_TMP/log-$run"
        echo "FAIL run $run"
        exit 1
    fi
done
sed -E 's/^[0-9-]+ [0-9:]+ //' "$TEST_TMP/log-1" "$TEST_TMP/log-2" > "$TEST_TMP/log"
cp "$TEST_TMP/state/proposals.csv" "$TEST_TMP/out/"
cp "$TEST_TMP/log" "$TEST_TMP/out/"

if [[ ${UPDATE:-} == 1 ]]; then
    mkdir -p "$here/expected"
    cp "$TEST_TMP/out/"* "$here/expected/"
fi
status=0

# Money conversion, exact in integers (see lib/wallet.sh).
# shellcheck source=lib/wallet.sh
source "$here/../lib/wallet.sh"
money() {
    local got
    got=$("$1" "$2")
    if [[ $got == "$3" ]]; then echo "ok   $1 $2 = $3"; else echo "FAIL $1 $2 = $got, expected $3"; status=1; fi
}
money xmr4 0 0.0000
money xmr4 1 0.0000                         # 1 atomic unit: below 0.0001, never rounded up
money xmr4 123450000000 0.1234              # 0.12345 is cut, not rounded to 0.1235
money xmr4 1234500000000 1.2345             # /1e12 in floating point gives 1.23449999..
money xmr4 99999960000000 99.9999           # 99.99996 is not shown as 100
money xmr4 18000000000000000 18000.0000     # beyond 2^53 atomic (~9007 XMR), where jq rounds
money xmr4 9007199254740993 9007.1992
money xmr4_number 0 0                       # numbers in the JSON: same text on jq 1.6 and 1.7
money xmr4_number 14000000000000 14
money xmr4_number 120000000000 0.12
money xmr4_number 10500000000000 10.5
money to_atomic 85 85000000000000
money to_atomic 240.12021 240120210000000
money to_atomic 0.000000000001 1
money to_atomic 1.0000000000019 1000000000001  # more than 12 decimals: cut
money to_atomic 085 85000000000000

for f in proposals.json completed-proposals.json projects.json proposals.csv log; do
    if diff -u "$here/expected/$f" "$TEST_TMP/out/$f"; then echo "ok   $f"; else echo "FAIL $f"; status=1; fi
done
exit "$status"

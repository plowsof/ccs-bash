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
cp "$FIXTURES/state.tsv" "$TEST_TMP/state/proposals.tsv"
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
cp "$TEST_TMP/state/proposals.tsv" "$TEST_TMP/out/"
cp "$TEST_TMP/log" "$TEST_TMP/out/"

if [[ ${UPDATE:-} == 1 ]]; then
    mkdir -p "$here/expected"
    cp "$TEST_TMP/out/"* "$here/expected/"
fi
status=0
for f in proposals.json complete.json proposals.tsv log; do
    if diff -u "$here/expected/$f" "$TEST_TMP/out/$f"; then echo "ok   $f"; else echo "FAIL $f"; status=1; fi
done
exit "$status"

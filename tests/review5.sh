# shellcheck shell=bash
# shellcheck disable=SC2154,SC2034  # (sourced by run.sh: its here, status, TEST_TMP and FIXTURES)
# Security review 5 (2026-10-27), state and backups: sourced by run.sh before its last comparison.
# A taken-over backend (or backup machine) keeping false totals past being found: a deposits.csv
# checked "in the future" by way of bash's 64-bit wrap; retired-record backups that merge
# proposals, or come under a new name; a state with two proposals' subaddresses swapped.
r5_had=$(cat "$TEST_TMP/wallet-count"); cp "$TEST_TMP/wallet-labels" "$TEST_TMP/wallet-labels.r5" 2> /dev/null || : > "$TEST_TMP/wallet-labels.r5"
r5_run() {   # r5_run DIR [ENV...]: one ccs-back.sh run on DIR/state, DIR/out; log in DIR/log
    local d=$1; shift
    mkdir -p "$d/state" "$d/out"
    [[ ! -f $d/ccs.conf ]] || chmod 644 "$d/ccs.conf"
    sed "s|$TEST_TMP/state|$d/state|; s|$TEST_TMP/out|$d/out|" "$TEST_TMP/ccs.conf" > "$d/ccs.conf" && chmod 444 "$d/ccs.conf"
    # shellcheck disable=SC2016
    env "$@" bash -c 'source "$1/../ccs-back.sh" && source "$1/stubs.sh" && main "$2"' _ "$here" "$d/ccs.conf" 2> "$d/log"
}
r5_raised() { jq -r --arg f "$2" '.[] | select(.filename == $f) | "\(.raised_amount) \(.contributions)"' "$1/out/projects.json"; }
r5_host() { type -P du head comm sort find > /dev/null; }   # (the backup receiver: a host script)

# deposits.csv checked at 2^64 + now: bash would read it as now, never recount in full, and a
# forged deposit would count every run. Refused by the run and by the backup receiver.
d=$TEST_TMP/r5-1; rm -rf "$d"; mkdir -p "$d/state"; cp "$TEST_TMP/state/proposals.csv" "$d/state/"
r5_run "$d" > /dev/null 2>&1 || true   # (a first run: deposits.csv made)
now=$(date +%s) lo=$((3709551616 + now - 100)) hi=1844674407
((lo < 10000000000)) || { hi=$((hi + 1)); lo=$((lo - 10000000000)); }
wrapped=$(printf '%d%010d' "$hi" "$lo")   # 2^64 + now - 100, as text
{ awk -v t="$wrapped" 'NR == 1 { sub(/checked [0-9]+$/, "checked " t) } { print }' "$d/state/deposits.csv"; printf '3099960,%064d,1,1000000000000000,0\n' 9; } > "$d/state/deposits.new"
mv "$d/state/deposits.new" "$d/state/deposits.csv"; cp "$d/state/deposits.csv" "$TEST_TMP/r5-1.deposits"
if ! r5_run "$d" && grep -q 'not a deposits file' "$d/log"; then
    echo "ok   review 5: deposits.csv checked at 2^64 + now: the run stops (no number past 18 digits)"
else echo "FAIL review 5: deposits.csv checked at 2^64 + now: a-fund $(r5_raised "$d" a-fund.md)"; status=1; fi
# an unlock_time of 2^64 - 1 (anyone can send one): locked for good, not counted as raised
d=$TEST_TMP/r5-1b; rm -rf "$d"; mkdir -p "$d/state"; cp "$TEST_TMP/state/proposals.csv" "$d/state/"
jq '.in += [{txid: ("e1" + ("0" * 62)), amount: 5000000000000, confirmations: 50, unlock_time: 18446744073709551615, subaddr_index: {major: 0, minor: 1}, height: 3099900}]' \
    "$FIXTURES/rpc/get_transfers.json" > "$TEST_TMP/r5-locked.json"
if r5_run "$d" TEST_TRANSFERS="$TEST_TMP/r5-locked.json" && [[ $(r5_raised "$d" a-fund.md) == "$(r5_raised "$TEST_TMP" a-fund.md)" ]]; then
    echo "ok   review 5: a deposit locked until 2^64 - 1: not counted (bash would have wrapped it to unlocked)"
else echo "FAIL review 5: a deposit locked for good: a-fund $(r5_raised "$d" a-fund.md), log: $(tail -n 2 "$d/log")"; status=1; fi
if r5_host; then
    bk=$TEST_TMP/r5-backup1; mkdir -p "$bk"
    if ! CCS_BACKUP_DIR=$bk "$here/../contrib/ccs-backup-receive" < "$TEST_TMP/r5-1.deposits" > "$d/recv.out" 2>&1 && grep -q 'not a deposits.csv' "$d/recv.out"; then
        echo "ok   review 5: the backup receiver refuses deposits.csv checked at 2^64 + now"
    else echo "FAIL review 5: the backup receiver keeps deposits.csv checked at 2^64 + now ($(cat "$d/recv.out"))"; status=1; fi
fi

# Retired records on the backup machine: only names its admin listed; a later version may rename
# proposals one for one, never put two proposals' deposits under one; a name with "-" is another
# wallet, never a version of a shorter one.
if r5_host; then
    bk=$TEST_TMP/r5-backup2; rm -rf "$bk"; mkdir -p "$bk"; printf 'ccs2\nccs2-0\n' > "$bk.names"
    rv() { CCS_BACKUP_DIR=${2:-$bk} CCS_BACKUP_RETIRED=$bk.names "$here/../contrib/ccs-backup-receive" > "$TEST_TMP/r5-recv.out" 2>&1; }
    w=8$(printf '%094d' 7)
    hdr() { printf '# retired %s wallet %s height 100 time 1700000000\n' "$1" "$w"; }
    { hdr ccs2; printf '10,%064d,1,1000000000000,0,a-fund.md\n11,%064d,2,2000000000000,0,b-wip.md\n12,%064d,3,3000000000000,0,near-funded.md\n' 1 2 3; } > "$TEST_TMP/r5-ccs2.csv"
    rv < "$TEST_TMP/r5-ccs2.csv" || true; sleep 1
    if ! { hdr ccs2; printf '10,%064d,1,1000000000000,0,a-fund.md\n11,%064d,2,2000000000000,0,a-fund.md\n12,%064d,3,3000000000000,0,a-fund.md\n' 1 2 3; } | rv \
        && grep -q 'more than renamed files' "$TEST_TMP/r5-recv.out" \
        && { hdr ccs2; printf '10,%064d,1,1000000000000,0,a-fund-2.md\n11,%064d,2,2000000000000,0,b-wip.md\n12,%064d,3,3000000000000,0,near-funded.md\n' 1 2 3; } | rv; then
        echo "ok   review 5: a later retired version may rename a proposal, not put three proposals' deposits under one"
    else cat "$TEST_TMP/r5-recv.out"; echo "FAIL review 5: a retired version merging proposals"; status=1; fi
    if ! { hdr ccs2-z; printf '10,%064d,1,9000000000000000,0,a-fund.md\n' 9; } | rv && grep -q "isn't in" "$TEST_TMP/r5-recv.out"; then
        echo "ok   review 5: a retired wallet the backup machine's admin didn't list is refused"
    else cat "$TEST_TMP/r5-recv.out"; echo "FAIL review 5: a new retired name with 9000 XMR kept"; status=1; fi
    bk2=$TEST_TMP/r5-backup3; rm -rf "$bk2"; mkdir -p "$bk2"
    { hdr ccs2-0; printf '10,%064d,1,1,0,a-fund.md\n' 9; } | rv - "$bk2" || true; sleep 1
    if rv - "$bk2" < "$TEST_TMP/r5-ccs2.csv" && [[ $(find "$bk2" -name 'retired-ccs2-2*.csv' | wc -l) == 1 ]]; then
        echo "ok   review 5: retired names don't share versions by prefix (ccs2-0 isn't ccs2's first version)"
    else cat "$TEST_TMP/r5-recv.out"; echo "FAIL review 5: ccs2-0 taken as ccs2's first version"; status=1; fi
    # (a leading zero, which the backend refuses: a restored copy would stop every run)
    mkdir -p "$TEST_TMP/r5-backup4"
    if ! { printf '# retired ccs2 wallet %s height 0100 time 01700000000\n' "$w"; printf '10,%064d,1,1,0,a-fund.md\n' 1; } | rv - "$TEST_TMP/r5-backup4"; then
        echo "ok   review 5: the backup refuses a retired header with a leading zero"
    else echo "FAIL review 5: a retired header with a leading zero kept"; status=1; fi
fi

# A state with two proposals' subaddresses swapped: each address is the wallet's, but the
# wallet's labels say which proposal each was given. The run stops.
d=$TEST_TMP/r5-5; rm -rf "$d"; mkdir -p "$d/state"
a1=8$(printf '%094d' 1) a2=8$(printf '%094d' 2)
sed -e "s/^\"a-fund.md\",\"\([^\"]*\)\",\"1\",\"$a1\"/\"a-fund.md\",\"\1\",\"2\",\"$a2\"/" \
    -e "s/^\"b-wip.md\",\"\",\"2\",\"$a2\"/\"b-wip.md\",\"\",\"1\",\"$a1\"/" "$FIXTURES/state.csv" > "$d/state/proposals.csv"
echo 4 > "$TEST_TMP/wallet-count"; printf '1 a-fund.md\n2 b-wip.md\n3 near-funded.md\n' > "$TEST_TMP/wallet-labels"
if ! grep -q "\"a-fund.md\",.*,\"2\",\"$a2\"" "$d/state/proposals.csv"; then
    echo "FAIL review 5: the swapped state fixture didn't swap"; status=1
elif ! r5_run "$d" && grep -q "labelled a-fund.md, given to b-wip.md" "$d/log"; then
    echo "ok   review 5: a state with two proposals' subaddresses swapped (against the wallet's labels): the run stops"
else echo "FAIL review 5: a swapped state runs: $(tail -n 1 "$d/log")"; status=1; fi

echo "$r5_had" > "$TEST_TMP/wallet-count"; cp "$TEST_TMP/wallet-labels.r5" "$TEST_TMP/wallet-labels"

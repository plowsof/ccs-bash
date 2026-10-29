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

# Review 5, low findings.
# D-5: dust at the next subaddress to be handed out (the state's highest + 1; the list publishes
# it) before a proposal is given it isn't that proposal's: not on this run, nor any later one.
d=$TEST_TMP/r5-dust; rm -rf "$d"; mkdir -p "$d/state"; cp "$FIXTURES/state.csv" "$d/state/proposals.csv"
echo 30 > "$TEST_TMP/wallet-count"; printf '1 a-fund.md\n2 b-wip.md\n3 near-funded.md\n' > "$TEST_TMP/wallet-labels"
jq '.in += [range(25) as $k | {txid: ("d0" + ("0" * 60) + ($k | tostring | if length == 1 then "0" + . else . end)), amount: 1, confirmations: 50, unlock_time: 0, subaddr_index: {major: 0, minor: 4}, height: 3099900}]' \
    "$FIXTURES/rpc/get_transfers.json" > "$TEST_TMP/r5-dust.json"
dust() { jq -r '.[] | select(.address == "8'"$(printf '%094d' 4)"'") | "\(.filename) \(.raised_amount) \(.contributions)"' "$d/out/projects.json" 2> /dev/null; }
r5_run "$d" TEST_TRANSFERS="$TEST_TMP/r5-dust.json" || true; first=$(dust)
r5_run "$d" TEST_TRANSFERS="$TEST_TMP/r5-dust.json" || true; second=$(dust)
if [[ $first == *" 0 0" && $second == "$first" ]] && grep -qE $'^4\t[0-9]+$' "$d/state/assigned.tsv" 2> /dev/null; then
    echo "ok   review 5: dust sent to a subaddress before it was handed out isn't the new proposal's ($first), on later runs either"
else echo "FAIL review 5: dust before a subaddress was handed out: '$first' then '$second'; assigned: $(cat "$d/state/assigned.tsv" 2>&1)"; status=1; fi

# D-6: retire-wallet, the wallet not answering about one address (a timeout): stops, writes nothing
# (it used to leave that proposal out of the record, silently)
d=$TEST_TMP/r5-retire; rm -rf "$d"; mkdir -p "$d/state"; cp "$TEST_TMP/state/proposals.csv" "$d/state/"
echo 6 > "$TEST_TMP/wallet-count"; : > "$TEST_TMP/wallet-labels"
jq --argjson m 10 '.pool = [] | .in |= map(select(.confirmations >= $m))' "$FIXTURES/rpc/get_transfers.json" > "$TEST_TMP/r5-quiet.json"
r5_run "$d" TEST_TRANSFERS="$TEST_TMP/r5-quiet.json" > /dev/null 2>&1 || true
a1=8$(printf '%094d' 1)
# shellcheck disable=SC2016
if ! R5_FAIL=$a1 TEST_TRANSFERS="$TEST_TMP/r5-quiet.json" bash -c 'source "$1/../contrib/retire-wallet" && source "$1/stubs.sh"
        eval "stub_$(declare -f rpc)"
        rpc() { if [[ $1 == get_address_index && $2 == *"$R5_FAIL"* ]]; then echo "curl: (28) Operation timed out" >&2; return 1; fi; stub_rpc "$@"; }
        retire_main old "$2"' _ "$here" "$d/ccs.conf" > "$d/retire.out" 2>&1 \
    && grep -q "could not ask the wallet about a-fund.md" "$d/retire.out" && [[ ! -e $d/state/retired/old.csv ]]; then
    echo "ok   review 5: retire-wallet stops when the wallet doesn't answer about an address (nothing written)"
else cat "$d/retire.out"; echo "FAIL review 5: retire-wallet with an address the wallet didn't answer about"; status=1; fi

# D-8: a run that hangs (here: the wallet never answers) is stopped after RUN_SECONDS, and its lock
# freed: the runs after it would otherwise skip ("still going") for good
d=$TEST_TMP/r5-hang; rm -rf "$d"; mkdir -p "$d/state" "$d/out"; cp "$TEST_TMP/state/proposals.csv" "$d/state/"
sed "s|$TEST_TMP/state|$d/state|; s|$TEST_TMP/out|$d/out|" "$TEST_TMP/ccs.conf" > "$d/ccs.conf" && chmod 444 "$d/ccs.conf"
# the lock free within 5 seconds (flock -n: the image's busybox flock has no -w)
r5_free() { local i; for i in 1 2 3 4 5; do (exec 8> "$d/state/lock"; flock -n 8) && return 0; sleep 1; done; return 1; }
start=$SECONDS rc=0
r5_hang() { RUN_SECONDS=2 bash -c 'source "$1/../ccs-back.sh" && source "$1/stubs.sh"; rpc() { while :; do sleep 1; done; }; main "$2"' _ "$here" "$d/ccs.conf" 2> "$d/log"; }
# (timeout only as a guard where there is one: the image has none)
# shellcheck disable=SC2016
if type -P timeout > /dev/null; then export -f r5_hang; export here d; timeout 60 bash -c r5_hang || rc=$?; else r5_hang || rc=$?; fi
if ((rc != 0 && SECONDS - start < 20)) && grep -q "the run took over 2s: stopped" "$d/log" && r5_free; then
    echo "ok   review 5: a run that hangs is stopped after RUN_SECONDS ($((SECONDS - start))s), its lock freed"
else echo "FAIL review 5: a hung run: exit $rc after $((SECONDS - start))s; log: $(grep -v "skipping\|ignoring" "$d/log")"; status=1; fi

# D-10: retire-from-ccs-back on a wallet restored from its keys (only subaddress 0 made): it makes
# them up to the state's highest index before asking which are its own, as every run does (one not
# made yet would answer "doesn't belong", and the live wallet's proposal would be retired)
d=$TEST_TMP/dep-db
if [[ -f $d/state/proposals.csv.before-retire-old0 ]]; then
    cp "$d/state/proposals.csv.before-retire-old0" "$d/state/proposals.csv"; rm -f "$d/state/retired/r5.csv"
    echo 1 > "$TEST_TMP/wallet-count"; : > "$TEST_TMP/wallet-labels"
    bash -c 'source "$1/../contrib/migrate/retire-from-ccs-back" && source "$1/stubs.sh" && retire_db_main r5 "$2" "$3"' _ "$here" "$d/ccs.conf" "$d/export" > "$d/db-r5.out" 2>&1 || true
    if (($(cat "$TEST_TMP/wallet-count") > 900)); then
        echo "ok   review 5: retire-from-ccs-back makes the wallet's subaddresses up to the state's highest first ($(cat "$TEST_TMP/wallet-count"))"
    else cat "$d/db-r5.out"; echo "FAIL review 5: retire-from-ccs-back asked a wallet with $(cat "$TEST_TMP/wallet-count") subaddresses made"; status=1; fi
    cp "$d/state/proposals.csv.before-retire-old0" "$d/state/proposals.csv"; rm -f "$d/state/retired/r5.csv"
else echo "FAIL review 5: no retire-from-ccs-back fixture (dep-db)"; status=1; fi

echo "$r5_had" > "$TEST_TMP/wallet-count"; cp "$TEST_TMP/wallet-labels.r5" "$TEST_TMP/wallet-labels"

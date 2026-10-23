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
WALLET_ADDRESS=8$(printf '%094d' 0)
CONF
chmod 444 "$TEST_TMP/ccs.conf"   # not writable, like the root-owned config ccs-bash insists on

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
# A different wallet (another main address) must stop the run, before anything is written.
cp -r "$TEST_TMP/out" "$TEST_TMP/out-before"
# shellcheck disable=SC2016
if bash -c 'source "$1/../ccs-back.sh" && source "$1/stubs.sh" && fake_address() { printf "9%094d" "$1"; } && main "$2"' \
    _ "$here" "$TEST_TMP/ccs.conf" 2> "$TEST_TMP/log-wrong-wallet"; then
    echo "FAIL run with a different wallet did not stop"; exit 1
fi
if ! grep -q "main address is not WALLET_ADDRESS" "$TEST_TMP/log-wrong-wallet" \
    || ! diff -r -q "$TEST_TMP/out-before" "$TEST_TMP/out" > /dev/null; then
    cat "$TEST_TMP/log-wrong-wallet"; echo "FAIL run with a different wallet"; exit 1
fi
rm -r "$TEST_TMP/out-before"
wrong_wallet="ok   a different wallet stops the run"
# A lost state file must stop the run instead of handing out new addresses: missing, or
# emptied while donations sit at subaddresses it used to know. Nothing may be created or written.
lost_state() {
    local name=$1 d=$TEST_TMP/lost-$1 before
    mkdir -p "$d"
    cp -r "$TEST_TMP/state" "$d/state" && cp -r "$TEST_TMP/out" "$d/out"
    sed "s|$TEST_TMP/state|$d/state|; s|$TEST_TMP/out|$d/out|" "$TEST_TMP/ccs.conf" > "$d/ccs.conf" && chmod 444 "$d/ccs.conf"
    case $name in
        missing) rm "$d/state/proposals.csv" ;;
        emptied) : > "$d/state/proposals.csv" ;;
    esac
    before=$(cat "$TEST_TMP/wallet-count")
    # shellcheck disable=SC2016
    if bash -c 'source "$1/../ccs-back.sh" && source "$1/stubs.sh" && main "$2"' _ "$here" "$d/ccs.conf" 2> "$d/log"; then
        echo "FAIL state file $name: the run did not stop"; exit 1
    fi
    if [[ $(cat "$TEST_TMP/wallet-count") != "$before" ]] || ! diff -r -q "$TEST_TMP/out" "$d/out" > /dev/null; then
        cat "$d/log"; echo "FAIL state file $name: the run still changed something"; exit 1
    fi
    lost+="ok   state file $name: the run stops ($(grep -o 'error: .*' "$d/log" | cut -c8-64)...)"$'\n'
}
lost=
lost_state missing
lost_state emptied

# A wallet that hands out a subaddress already in use must stop the run: a fresh copy of the
# fixture state, so there are new proposals to give addresses to.
d=$TEST_TMP/reuse
mkdir -p "$d/state" "$d/out"
cp "$FIXTURES/state.csv" "$d/state/proposals.csv"
sed "s|$TEST_TMP/state|$d/state|; s|$TEST_TMP/out|$d/out|" "$TEST_TMP/ccs.conf" > "$d/ccs.conf" && chmod 444 "$d/ccs.conf"
echo 1 > "$TEST_TMP/wallet-count"
# shellcheck disable=SC2016
if TEST_REUSE_INDEX=1 bash -c 'source "$1/../ccs-back.sh" && source "$1/stubs.sh" && main "$2"' _ "$here" "$d/ccs.conf" 2> "$d/log"; then
    echo "FAIL a reused subaddress did not stop the run"; exit 1
fi
grep -q "already goes up to" "$d/log" || { cat "$d/log"; echo "FAIL reused subaddress: wrong reason"; exit 1; }
# (the new proposals do get recorded, just not with an address)
[[ $(grep -c "$(printf '8%094d' 1)" "$d/state/proposals.csv") == 1 ]] || { echo "FAIL reused subaddress: given out twice"; exit 1; }
reuse="ok   a wallet handing out a used subaddress stops the run"

sed -E "s/^[0-9-]+ [0-9:]+ //; s|$TEST_TMP|<tmp>|g" "$TEST_TMP/log-1" "$TEST_TMP/log-2" > "$TEST_TMP/log"
cp "$TEST_TMP/state/proposals.csv" "$TEST_TMP/out/"
cp "$TEST_TMP/log" "$TEST_TMP/out/"

if [[ ${UPDATE:-} == 1 ]]; then
    mkdir -p "$here/expected"
    cp "$TEST_TMP/out/"* "$here/expected/"
fi
status=0
echo "$wrong_wallet"
printf '%s' "$lost"
echo "$reuse"

# Money conversion, exact in integers (see lib/wallet.sh).
# shellcheck source=lib/common.sh
source "$here/../lib/common.sh"
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

# Odd entries in the proposals repo are skipped, never stop or hang the run: a directory
# and a symlink named like a proposal, a backslash and invalid UTF-8 in a name.
# shellcheck source=lib/proposals.sh
source "$here/../lib/proposals.sh"
CCS_LIB=$here/../lib
odd=$(mktemp -d)
cp "$FIXTURES/proposals/b-wip.md" "$odd/good.md"
mkdir "$odd/dir.md"
ln -s good.md "$odd/link.md"
mkfifo "$odd/fifo.md"
cp "$odd/good.md" "$odd/back\\slash.md"
cp "$odd/good.md" "$odd/bad"$'\xff'".md"
got=$(read_proposals "$odd" 2> "$odd.log" | jq -r '[.[].file] | join(" ")')
if [[ $got == good.md && $(grep -c skipping "$odd.log") == 5 ]]; then
    echo "ok   odd proposal files are skipped (directory, symlink, fifo, backslash, bad UTF-8)"
else
    cat "$odd.log"; echo "FAIL odd proposal files: read $got"; status=1
fi
# Frontmatter that YAML (so Jekyll) reads differently from a simple key: value: read the way
# YAML does, or skipped. Each case: expected title (or "skip") and the lines after "layout: cp".
yaml=$(mktemp -d)
yaml_cases=(
    "Talks|title: Talks #2: April"
    "A #1|title: \"A #1\" # note"
    "It's|title: 'It''s'"
    "x|title: 'x' # note"
    "Fine|# title: Evil|title: Fine"
    "skip|title: Foo|  bar"
    "skip|title: >|  Foo"
    "skip|title: \"Foo|  bar\""
    "skip|title: \"a\\\"b\""
    "skip|title: [a]"
    "skip|title: &a X"
    "skip|title: a: b"
    "skip|title:Foo"
    "skip|\"title\": Other|title: X"
    "skip|title: 'a' b"
)
i=0
for c in "${yaml_cases[@]}"; do
    i=$((i + 1))
    { printf -- '---\nlayout: cp\n'; printf '%s\n' "${c#*|}" | tr '|' '\n'
      printf 'author: a\ndate: 2021-06-25\namount: 1\nmilestones:\n  - name: m\n    done: yes\n---\n'; } > "$yaml/$i.md"
done
sed 's/^  //' "$yaml/1.md" > "$yaml/zero.md"   # a list at column 0 is the same list
printf '\357\273\277' | cat - "$yaml/1.md" > "$yaml/bom.md"   # Jekyll sees no frontmatter either
yaml_ok=1
i=0
for c in "${yaml_cases[@]}"; do
    i=$((i + 1))
    got=$(awk -f "$CCS_LIB/frontmatter.awk" "$yaml/$i.md" 2> /dev/null | cut -f3,5,8,9)
    [[ $got ]] || got=skip
    want=${c%%|*}
    [[ $want == skip ]] || want="$want"$'\t'"2021 6 25"$'\t1\t1'
    [[ $got == "$want" ]] || { echo "FAIL frontmatter case $i ($c): got '$got'"; yaml_ok=0; }
done
[[ $(awk -f "$CCS_LIB/frontmatter.awk" "$yaml/zero.md" | cut -f8,9) == $'1\t1' ]] || { echo "FAIL a list at column 0"; yaml_ok=0; }
[[ $(awk -f "$CCS_LIB/frontmatter.awk" "$yaml/bom.md" 2>&1) == *"no frontmatter"* ]] || { echo "FAIL a BOM file was read"; yaml_ok=0; }
# a bad line is quoted in the log: without its terminal escapes
printf -- '---\nlayout: cp\ntitle: T\n\033[2Jgone\a\nauthor: a\ndate: 2021-06-25\namount: 1\nmilestones:\n  - name: m\n---\n' > "$yaml/esc.md"
esc=$(awk -f "$CCS_LIB/frontmatter.awk" "$yaml/esc.md" 2>&1; log $'x\x1b[2Jy' 2>&1)
[[ $esc == *"?[2Jgone?"*"x?[2Jy" && $esc != *$'\x1b'* ]] || { echo "FAIL control characters reach the log: ${esc//$'\x1b'/^[}"; yaml_ok=0; }
# The same files through Ruby's YAML, which Jekyll uses: every title read must match it.
if command -v ruby > /dev/null; then
    for f in "$yaml"/[0-9]*.md; do
        got=$(awk -f "$CCS_LIB/frontmatter.awk" "$f" 2> /dev/null | cut -f3)
        [[ $got ]] || continue
        # shellcheck disable=SC2016
        ruby_title=$(ruby -rdate -ryaml -e 'puts YAML.safe_load(File.read(ARGV[0]).split(/^---$/)[1], permitted_classes: [Date])["title"]' "$f")
        [[ $got == "$ruby_title" ]] || { echo "FAIL ${f##*/}: title '$got', YAML reads '$ruby_title'"; yaml_ok=0; }
    done
elif [[ ${CI:-} == true ]]; then
    echo "FAIL ruby not installed"; yaml_ok=0
fi
if ((yaml_ok)); then echo "ok   frontmatter is read like YAML reads it, or skipped (${#yaml_cases[@]} cases, list at column 0, BOM)"; else status=1; fi
rm -rf "$yaml"

if [[ $(read_proposals "$(mktemp -d)" 2> /dev/null) == '[]' ]]; then echo "ok   no proposals at all is an empty list"; else echo "FAIL no proposals"; status=1; fi
rm -rf "$odd" "$odd.log"

# One MR that can't be read leaves out only that MR from the ideas (13 here; 11 stays).
# shellcheck source=lib/gitlab.sh
source "$here/../lib/gitlab.sh"
got=$(
    # shellcheck source=tests/stubs.sh
    source "$here/stubs.sh"
    PROPOSALS_DIR=$FIXTURES/proposals TEST_FAIL_MR=13 ideas 2> /dev/null | jq -r '[.[]."gitlab-url"] | join(" ")'
)
if [[ $got == https://example.org/mr/11 ]]; then echo "ok   one unreadable MR leaves only that one out of the ideas"; else echo "FAIL one unreadable MR: ideas were '$got'"; status=1; fi

# atomic_write: a failed or silent command leaves the old file alone.
aw=$(mktemp -d)
echo old > "$aw/f"
atomic_write "$aw/f" false 2> /dev/null || true
atomic_write "$aw/f" true 2> /dev/null || true
atomic_write "$aw/f" sh -c 'echo half; exit 1' 2> /dev/null || true
if [[ $(cat "$aw/f") == old && $(ls -A "$aw") == f ]]; then echo "ok   a failed write keeps the old file"; else echo "FAIL a failed write replaced the old file"; status=1; fi
if atomic_write "$aw/f" echo new && [[ $(cat "$aw/f") == new ]]; then echo "ok   a good write replaces it"; else echo "FAIL a good write"; status=1; fi
rm -rf "$aw"

# A wallet that answers with something other than numbers must stop the run, never have it
# evaluated: bash arithmetic would run a command hidden in an array subscript.
evil=$(mktemp -d)
(
    MIN_CONFIRMATIONS=10
    rpc() { printf '{"in": [{"txid": "x", "amount": 1, "confirmations": "BASH_VERSINFO[$(:>%s/ran)]", "subaddr_index": {"minor": 1}}]}' "$evil"; }
    donation_totals
) > /dev/null 2>&1 || true
if [[ -e $evil/ran ]]; then echo "FAIL a command in the wallet's answer was run"; status=1; else echo "ok   a command in the wallet's answer is not run"; fi
rm -rf "$evil"

# verify-images.sh: a signature file counts for one maintainer at most. One holding the same
# signature twice (gpg then reports it twice) must not count, nor a key not trusted.
if command -v gpg > /dev/null; then
    sig=$(
        # shellcheck source=container/verify-images.sh
        source "$here/../container/verify-images.sh"
        tmp=$(mktemp -d)
        trap 'rm -rf "$tmp"' EXIT
        export GNUPGHOME=$tmp/gnupg
        install -d -m 700 "$GNUPGHOME"
        key() { gpg -q --batch --passphrase '' --quick-gen-key "$1 <$1@invalid>" ed25519 sign never 2> /dev/null
                gpg --batch --with-colons --list-keys "$1@invalid" 2> /dev/null | awk -F: '$1 == "fpr" { print $10; exit }'; }
        good=$(key good) other=$(key other)
        echo "$good" > "$tmp/trusted"
        m=sha256:$(printf '%064d' 1)
        printf '{"critical":{"identity":{"docker-reference":"stagex/core-x:1"},"image":{"docker-manifest-digest":"%s"},"type":"atomic container signature"},"optional":{}}' "$m" > "$tmp/p"
        s() { gpg -q --batch -z0 -u "$1" --output "$tmp/$2" --sign "$tmp/p"; }
        s "$good" one && s "$other" untrusted
        gpg -q --batch -z0 --output "$tmp/lit" --store "$tmp/p"
        gpg -q --batch -u "$good" --output "$tmp/det" --detach-sign "$tmp/p"
        cat "$tmp/det" "$tmp/det" "$tmp/lit" > "$tmp/twice"
        for f in one twice untrusted; do
            printf '%s=%s ' "$f" "$(signature_signer "$tmp/$f" stagex/core-x "$m" | cut -c1-4)"
        done
        printf 'wrong-image=%s' "$(signature_signer "$tmp/one" stagex/core-y "$m")"
    )
    if [[ $sig == "one="????" twice= untrusted= wrong-image=" ]]; then
        echo "ok   a signature counts once, only by a trusted key, only for its image"
    else
        echo "FAIL signature check: $sig"; status=1
    fi
elif [[ ${CI:-} == true ]]; then
    echo "FAIL gpg not installed"; status=1
fi

# notify-loop.sh: a flood of notifications gives at most one run per GAP, and none without one.
nl=$(mktemp -d)
FLAG=$nl/new-tx GAP=2 EVERY=1000 "$here/../notify-loop.sh" bash -c "echo run >> $nl/runs" &
loop=$!
end=$((SECONDS + 6))
n=0
while ((SECONDS < end)); do touch "$nl/new-tx"; n=$((n + 1)); done   # 6 seconds of notifications
sleep 3                                                        # the last one still gets its run
spam=$(wc -l < "$nl/runs")
sleep 3                                                        # then 3 quiet seconds
quiet=$(wc -l < "$nl/runs")
kill "$loop"
# 1 at the start, then one per 2 seconds: 3 more (+-1 for where the seconds fall). No GAP gives 7+
if ((spam >= 3 && spam <= 5 && quiet == spam)); then
    echo "ok   notify-loop: $n notifications in 6s gave $spam runs, none after"
else
    echo "FAIL notify-loop: $spam runs during the flood, $quiet after"; status=1
fi
rm -rf "$nl"

# The real qrencode, read back with a real decoder (zbarimg, only needed here): a QR code
# made for an address must read back as exactly that. CI must not skip this.
if command -v qrencode > /dev/null && command -v zbarimg > /dev/null; then
    uri=monero:$(printf '8%094d' 1)
    if qrencode -s 10 -o "$TEST_TMP/qr.png" "$uri" && [[ $(zbarimg --quiet --raw "$TEST_TMP/qr.png" 2> /dev/null) == "$uri" ]]; then
        echo "ok   real qrencode + zbarimg round trip"
    else
        echo "FAIL real qrencode + zbarimg round trip"; status=1
    fi
elif [[ ${CI:-} == true ]]; then
    echo "FAIL qrencode or zbarimg not installed"; status=1
else
    echo "skip real qrencode + zbarimg round trip (not installed)"
fi

for f in proposals.json completed-proposals.json projects.json proposals.csv log; do
    if diff -u "$here/expected/$f" "$TEST_TMP/out/$f"; then echo "ok   $f"; else echo "FAIL $f"; status=1; fi
done
exit "$status"

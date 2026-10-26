#!/usr/bin/env bash
# End-to-end test: runs ccs-back.sh against tests/fixtures, with the wallet and GitLab
# replaced by tests/stubs.sh, then compares with tests/expected.
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
# tags: a list (or one on the line), at most 5 of up to 40 bytes; a tags: we can't read
# drops the tags with a log line, never the proposal. Each case: tags wanted (| between) and
# the lines after the milestones.
tag_cases=(
    "A|B|tags:|  - A|  - 'B' # note|  - A"
    "A|tags: A"
    "Col|tags:|- Col"
    "|tags: []"
    "|tags: [a, b]"
    "|tags:|  - a: b"
    "|tags:|  - 1|  - 2|  - 3|  - 4|  - 5|  - 6"
    "|tags:|  - $(printf 'x%.0s' {1..41})"
)
i=0
for c in "${tag_cases[@]}"; do
    i=$((i + 1))
    want=${c%%tags*}; want=${want%|}
    { printf -- '---\nlayout: cp\ntitle: T\nauthor: a\ndate: 2021-06-25\namount: 1\nmilestones:\n  - name: m\n'
      printf '%s\n' "tags${c#*|tags}" | tr '|' '\n'; printf -- '---\n'; } > "$yaml/tag$i.md"
    got=$(awk -f "$CCS_LIB/frontmatter.awk" "$yaml/tag$i.md" 2> /dev/null | cut -f3,10 | tr '\037' '|')
    [[ $got == "T"$'\t'"$want" ]] || { echo "FAIL tags case $i ($c): got '$got'"; yaml_ok=0; }
done
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
    WORK=$(mktemp -d) PROPOSALS_DIR=$FIXTURES/proposals TEST_FAIL_MR=13 ideas 2> /dev/null | jq -r '[.[]."gitlab-url"] | join(" ")'
)
if [[ $got == https://example.org/mr/11 ]]; then echo "ok   one unreadable MR leaves only that one out of the ideas"; else echo "FAIL one unreadable MR: ideas were '$got'"; status=1; fi
# Anyone can open an MR: an address in its title is shortened, also when invisible characters
# (a left-to-right mark, a zero-width space) split it, and words around it stay
addr=44AFFq5kSiGBoZ4NMDwYtN18obc8AemS33DBLWs3H7otXft3XjrpDtQGv7SqSsaBYBb98uNbr2VBBEt7f2wfn3RVGQBEP3A
fx=$(mktemp -d); cp -r "$FIXTURES/." "$fx"
jq --arg t "Pay naïve me: ${addr:0:30}"$'\xe2\x80\x8e'"${addr:30:30}"$'\xe2\x80\x8b'"${addr:60}!" 'map(if .iid == 11 then .title = $t else . end)' \
    "$FIXTURES/gitlab/opened.json" > "$fx/gitlab/opened.json"
got=$(
    # shellcheck source=tests/stubs.sh
    source "$here/stubs.sh"
    WORK=$(mktemp -d) FIXTURES=$fx PROPOSALS_DIR=$here/fixtures/proposals ideas 2> /dev/null | jq -r '.[] | select(."gitlab-url" | endswith("/11")) | .name'
)
if [[ $got == 'Pay naïve me: 44AFFq…EP3A!' ]]; then echo "ok   an address in an idea's title is shortened, invisible characters in it or not"; else echo "FAIL an address in an idea's title: '$got'"; status=1; fi
# ... and when drawn with other characters (the web server's gate holds back the same): its halves
# in bidi embeddings, shown in another order than written; mathematical letters and digits;
# Cyrillic letters for some of its own. What is left has no bidi control, and no run of 90
# characters each base58 or not ASCII.
for how in bidi math cyrillic; do
    # (jq, not python: the tests also run inside the pinned image, which has none)
    t=$(jq -rn --arg a "$addr" --arg how "$how" '
        if $how == "bidi" then "Moved: \u202b\u202a" + $a[48:] + "\u202c\u202a " + $a[:48] + "\u202c\u202c"
        elif $how == "math" then "Pay: " + ($a | explode | map(if . >= 48 and . <= 57 then . + 120754 elif . >= 65 and . <= 90 then . + 120727 else . + 120729 end) | implode)
        else "Pay: " + ($a | gsub("A"; "\u0410") | gsub("B"; "\u0412") | gsub("E"; "\u0415")) end')
    jq --arg t "$t" 'map(if .iid == 11 then .title = $t else . end)' "$FIXTURES/gitlab/opened.json" > "$fx/gitlab/opened.json"
    got=$(
        # shellcheck source=tests/stubs.sh
        source "$here/stubs.sh"
        WORK=$(mktemp -d) FIXTURES=$fx PROPOSALS_DIR=$here/fixtures/proposals ideas 2> /dev/null | jq -r '.[] | select(."gitlab-url" | endswith("/11")) | .name'
    )
    if [[ $got == Pay* || $got == Moved* ]] && jq -en --arg s "$got" '$s | (test("[\u202a-\u202e\u2066-\u2069]")
        or test("(?:[1-9A-HJ-NP-Za-km-z]|[^\\x00-\\x7F]){90}")) | not' > /dev/null; then
        echo "ok   an address in an idea's title, drawn with other characters ($how), is shortened or broken up"
    else
        echo "FAIL an address in an idea's title ($how): '$got'"; status=1
    fi
done
cp "$FIXTURES/gitlab/opened.json" "$fx/gitlab/opened.json"
# an idea's file over 1 MB isn't kept, nor read: that idea is left out (13 stays)
awk 'BEGIN { for (i = 0; i < 1048576; i += 64) printf "%63s\n", "" }' >> "$fx/gitlab/raw/sha-11"
got=$(
    # shellcheck source=tests/stubs.sh
    source "$here/stubs.sh"
    WORK=$(mktemp -d) FIXTURES=$fx PROPOSALS_DIR=$here/fixtures/proposals ideas 2>&1 > "$fx/ideas.json" | grep -c 'MR !11.*over 1048576 bytes'
    jq -r '[.[]."gitlab-url" | sub(".*/"; "")] | join(" ")' "$fx/ideas.json"
)
if [[ $got == $'1\n13' ]]; then echo "ok   an idea's file over 1 MB leaves that idea out"; else echo "FAIL an idea's file over 1 MB: '$got'"; status=1; fi
rm -rf "$fx"
# Ideas are open MRs adding exactly one new .md whose text reads as a proposal: not one that only
# edits a file (16), adds two (14), adds a proposal already merged (12), or adds junk (15). A file
# that can't be fetched leaves out only that idea, this run (13 here).
for fail in "" 13; do
    got=$(
        # shellcheck source=tests/stubs.sh
        source "$here/stubs.sh"
        WORK=$(mktemp -d) PROPOSALS_DIR=$FIXTURES/proposals TEST_FAIL_RAW=$fail ideas 2> /dev/null | jq -r '[.[]."gitlab-url" | sub(".*/"; "")] | sort | join(" ")'
    )
    want="11 13" what=""
    [[ -z $fail ]] || { want=11 what=" (MR $fail: its file can not be fetched)"; }
    if [[ $got == "$want" ]]; then
        echo "ok   ideas$what: only MRs adding one new proposal that reads ($got)"
    else
        echo "FAIL ideas$what: got '$got', want '$want'"; status=1
    fi
done

# Anyone can open MRs: what an MR adds at a commit, and whether its file reads, is kept
# (IDEAS_CACHE), so a second run fetches no proposal's text again (only what an MR whose file is
# already merged adds: 12 here, never kept) and gives the same ideas; and only the IDEAS_MAX most
# recently updated open MRs are looked at.
got=$(
    # shellcheck source=tests/stubs.sh
    source "$here/stubs.sh"
    run_ideas() { WORK=$(mktemp -d) PROPOSALS_DIR=$FIXTURES/proposals IDEAS_CACHE=$TEST_TMP/ideas.cache ideas; }
    : > "$TEST_TMP/gitlab-calls"
    first=$(run_ideas 2> /dev/null | jq -c .)
    fetched=$(grep -cE '/changes|/raw' "$TEST_TMP/gitlab-calls")
    : > "$TEST_TMP/gitlab-calls"
    second=$(run_ideas 2> /dev/null | jq -c .)
    again=$(grep -cE '/raw|changes-1[13-6]|merge_requests/1[13-6]/' "$TEST_TMP/gitlab-calls" || true)
    one=$(IDEAS_MAX=1 run_ideas 2>&1 > /dev/null | grep -c 'only the 1 most recently updated' || true)
    [[ $first == "$second" && $fetched -gt 0 && $again == 0 && $one == 1 ]] && echo same || echo "fetched $fetched, again $again, capped $one; $first / $second"
)
if [[ $got == same ]]; then echo "ok   ideas: what each MR adds is fetched once (IDEAS_CACHE), at most IDEAS_MAX MRs a run"; else echo "FAIL ideas' cache: $got"; status=1; fi

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

# The same proposals and MRs on Forgejo (git.disroot.org, codeberg.org...): REPOSITORY_URL
# .../api/v1/repos/<owner>/<repo>, the stubs answer as Forgejo does (pull requests, times with
# an offset, a closed PR that was not merged). The JSON and the state must be the GitLab run's.
fj=$TEST_TMP/forgejo
mkdir -p "$fj/state" && cp "$FIXTURES/state.csv" "$fj/state/proposals.csv" && echo 1 > "$fj/wallet-count"
sed "s|^REPOSITORY_URL=.*|REPOSITORY_URL=https://forgejo.invalid/api/v1/repos/monero/ccs-proposals|; s|$TEST_TMP/state|$fj/state|; s|$TEST_TMP/out|$fj/out|" \
    "$TEST_TMP/ccs.conf" > "$fj/ccs.conf" && chmod 444 "$fj/ccs.conf"
fj_ok=1
for run in 1 2; do
    # shellcheck disable=SC2016
    TEST_TMP=$fj bash -c 'source "$1/../ccs-back.sh" && source "$1/stubs.sh" && main "$2"' _ "$here" "$fj/ccs.conf" 2> "$fj/log-$run" \
        || { cat "$fj/log-$run"; fj_ok=0; }
done
cp "$fj/state/proposals.csv" "$fj/out/"
for f in proposals.json completed-proposals.json projects.json proposals.csv; do
    diff -u "$here/expected/$f" "$fj/out/$f" || fj_ok=0
done
if ((fj_ok)); then echo "ok   Forgejo: the same JSON and state as GitLab"; else echo "FAIL Forgejo"; status=1; fi
# Images: a proposal's images are files in images/<proposal>/ in the repository; the ones its .md
# shows are copied (once, keeping their time) and listed; anything else stays a link.
img=$(mktemp -d)
(
    set -e
    # shellcheck source=lib/images.sh
    source "$here/../lib/images.sh"
    P=$img/props && mkdir -p "$P/images/my-proposal" "$P/images/other" "$img/out/images"
    printf '\x89PNG\r\n\x1a\nrest of a png' > "$P/images/my-proposal/chart.png"
    printf '<svg>not an image</svg>' > "$P/images/my-proposal/fake.png"
    { printf 'GIF89a'; printf '%03000d' 0; } > "$P/images/my-proposal/big.gif"
    printf '\x89PNG\r\n\x1a\nanother' > "$P/images/my-proposal/unused.png"
    printf '\x89PNG\r\n\x1a\nother' > "$P/images/other/x.png"
    printf -- '---\nlayout: fr\n---\n![a](images/my-proposal/chart.png "t") ![b](images/my-proposal/fake.png) ![c](images/my-proposal/big.gif)\n![d](images/other/x.png) ![e](https://elsewhere.example/e.png) ![f](images/my-proposal/missing.png)\n' > "$P/my-proposal.md"
    printf -- '---\nlayout: fr\n---\n![g](images/spaced name/x.png)\n' > "$P/spaced name.md"
    printf 'from v0.2.10' > "$img/out/images/0c1d2e3f-1111-2222-3333-444455556666.png"
    PROPOSALS_DIR=$P OUTPUT_DIR=$img/out WORK=$img IMAGE_MAX_BYTES=2000
    echo '[{"file": "my-proposal.md"}, {"file": "spaced name.md"}]' > "$WORK/props.json"
    proposal_images 2> "$img/log"
    jq -c . "$img/out/images.json" > "$img/map1"
    (cd "$img/out/images" && echo */*) > "$img/files1"
    [[ -e $img/out/images/0c1d2e3f-1111-2222-3333-444455556666.png ]] && echo leftover >> "$img/files1"
    src=$P/images/my-proposal/chart.png dst=$img/out/images/my-proposal/chart.png
    # the same time, to the second (rsync compares seconds)
    [[ $(date -r "$src" +%s) == "$(date -r "$dst" +%s)" ]] && echo same-time > "$img/time"
    proposal_images 2>> "$img/log"   # again: nothing to copy
    printf -- '---\nlayout: fr\n---\nNo images now.\n' > "$P/my-proposal.md"
    proposal_images 2>> "$img/log"
    (cd "$img/out/images" && echo */*) > "$img/files2"
    # Ideas: one new .md and its images, inside images/<its name>/; anything else isn't an idea
    gitlab_get() { jq -n --argjson f "$TEST_FILES" '{changes: ($f | map({new_file: true, new_path: .}))}'; }
    for set in '["pics.md", "images/pics/a.png", "images/pics/b.jpeg"]' '["pics.md", "images/pics/notes.txt"]' \
        '["pics.md", "images/other/a.png"]' '["pics.md", "a.png"]' '["pics.md", "more.md"]'; do
        printf '[%s] ' "$(TEST_FILES=$set mr_proposal_file 1)"
    done > "$img/ideas"
)
if [[ $(cat "$img/map1" 2> /dev/null) == '{"images/my-proposal/chart.png":"my-proposal/chart.png"}' \
    && $(cat "$img/files1") == my-proposal/chart.png && $(cat "$img/time" 2> /dev/null) == same-time ]] \
    && grep -q "fake.png is not a PNG, JPEG or GIF" "$img/log" && grep -q "big.gif is over 2000 bytes" "$img/log" \
    && grep -q "missing.png, which isn't in the repository" "$img/log" && [[ $(cat "$img/files2") == '*/*' ]]; then
    echo "ok   images: only images/<proposal>/ files its .md shows, real and small enough, copied once; the rest stay links"
else
    cat "$img/map1" "$img/files1" "$img/time" "$img/log" "$img/files2" 2> /dev/null; echo "FAIL images"; status=1
fi
if [[ $(cat "$img/ideas") == '[pics.md] [] [] [] [] ' ]]; then
    echo "ok   ideas: one new .md and its images (images/<its name>/), nothing else"
else
    cat "$img/ideas"; echo; echo "FAIL ideas with images"; status=1
fi
rm -rf "$img"

# Security review 2026-10-25 (fails until fixed): anyone can send a little to a subaddress no
# proposal has (the signed list publishes 15,000 of them); the wallet then knows it, and a run that
# stops on it stops the site updating for as long as that donation is there, which is for good.
d=$TEST_TMP/stranger
mkdir -p "$d/state" "$d/out"
cp -r "$FIXTURES" "$d/fx" && cp "$TEST_TMP/state/proposals.csv" "$d/state/"
jq '.in += [{txid: ("d" * 64), height: 3099950, amount: 1, confirmations: 50, unlock_time: 0, subaddr_index: {major: 0, minor: 14999}}]' \
    "$FIXTURES/rpc/get_transfers.json" > "$d/fx/rpc/get_transfers.json"
sed "s|$TEST_TMP/state|$d/state|; s|$TEST_TMP/out|$d/out|" "$TEST_TMP/ccs.conf" > "$d/ccs.conf" && chmod 444 "$d/ccs.conf"
had=$(cat "$TEST_TMP/wallet-count"); echo 15000 > "$TEST_TMP/wallet-count"
# shellcheck disable=SC2016
if FIXTURES=$d/fx bash -c 'source "$1/../ccs-back.sh" && source "$1/stubs.sh" && main "$2"' _ "$here" "$d/ccs.conf" 2> "$d/log"; then
    echo "ok   a stranger's donation to a subaddress no proposal has: the run goes on"
else
    echo "FAIL a stranger's donation to a subaddress no proposal has stops every run: $(grep -o 'error: .*' "$d/log" | cut -c8-80)"; status=1
fi
echo "$had" > "$TEST_TMP/wallet-count"

# deposits.csv: deposits 30+ blocks deep are kept, and a run asks the wallet only for what came
# after them; the totals are the same either way. A wallet below the file's height (rescanning)
# stops the run; so does, at the daily full recount, a wallet that lacks a kept deposit, while one
# it knows that the file lacks is added.
dep() {   # dep NAME [ENV...]: a run on a copy of the state, its own deposits.csv; its log in $d/log
    local name=$1; shift
    d=$TEST_TMP/dep-$name; mkdir -p "$d/state" "$d/out"
    [[ -f $d/state/proposals.csv ]] || cp "$TEST_TMP/state/proposals.csv" "$d/state/"
    sed "s|$TEST_TMP/state|$d/state|; s|$TEST_TMP/out|$d/out|" "$TEST_TMP/ccs.conf" > "$d/ccs.conf" && chmod 444 "$d/ccs.conf"
    : > "$TEST_TMP/get_transfers-calls"
    # shellcheck disable=SC2016
    env "$@" bash -c 'source "$1/../ccs-back.sh" && source "$1/stubs.sh" && main "$2"' _ "$here" "$d/ccs.conf" 2> "$d/log"
}
deposits_ok=1
if dep a && f=$TEST_TMP/dep-a/state/deposits.csv && [[ $(awk "NR == 1" "$f") =~ ^#\ final\ 3099970\ checked\ [0-9]+$ ]] \
    && [[ $(awk "NR > 1" "$f" | cut -d, -f1 | tr '\n' ' ') == "3099901 3099940 3099950 3099960 3099960 3099970 " ]] \
    && ! grep -q filter_by_height "$TEST_TMP/get_transfers-calls"; then
    first=$(jq -c . "$TEST_TMP/dep-a/out/projects.json")
    if dep a && grep -q '"filter_by_height":true,"min_height":3099970' <(jq -c . "$TEST_TMP/get_transfers-calls") \
        && [[ $(jq -c . "$TEST_TMP/dep-a/out/projects.json") == "$first" && $first == "$(jq -c . "$TEST_TMP/out/projects.json")" ]]; then
        echo "ok   deposits.csv: the deposits 30 deep kept; the next run asks only for what came after them, the same totals"
    else cat "$TEST_TMP/get_transfers-calls" "$TEST_TMP/dep-a/log"; echo "FAIL deposits.csv: the incremental run"; deposits_ok=0; fi
else cat "$TEST_TMP/dep-a/log"; cat "$TEST_TMP/dep-a/state/deposits.csv" 2> /dev/null; echo "FAIL deposits.csv: the first run"; deposits_ok=0; fi
if ! dep a TEST_HEIGHT=3000000 && grep -q 'the wallet is at height 3000000, below the 3099970' "$TEST_TMP/dep-a/log"; then
    echo "ok   deposits.csv: a wallet below the kept deposits' height (rescanning) stops the run"
else cat "$TEST_TMP/dep-a/log"; echo "FAIL deposits.csv: a rescanning wallet"; deposits_ok=0; fi
# the daily recount: a wallet without a kept deposit (t1's) stops the run; one with a deposit the
# file lacks (taken out of it here) adds it
sed -i '1s/checked [0-9]*/checked 0/' "$TEST_TMP/dep-a/state/deposits.csv"
jq '.in |= map(select(.txid | startswith("7431") | not))' "$FIXTURES/rpc/get_transfers.json" > "$TEST_TMP/without-t1.json"
if ! dep a TEST_TRANSFERS="$TEST_TMP/without-t1.json" && grep -q 'the wallet lacks 1 of the deposits kept' "$TEST_TMP/dep-a/log"; then
    echo "ok   deposits.csv: the daily recount, a wallet that lacks a kept deposit: the run stops"
else cat "$TEST_TMP/dep-a/log"; echo "FAIL deposits.csv: a deposit the wallet lost"; deposits_ok=0; fi
sed -i '/^3099950,/d' "$TEST_TMP/dep-a/state/deposits.csv"
if dep a && grep -q 'the wallet knows 1 deposit(s) below height 3099970' "$TEST_TMP/dep-a/log" \
    && grep -q '^3099950,' "$TEST_TMP/dep-a/state/deposits.csv" && [[ $(jq -c . "$TEST_TMP/dep-a/out/projects.json") == "$first" ]]; then
    echo "ok   deposits.csv: the daily recount, a deposit the wallet knows and the file lacked: added, the same totals"
else cat "$TEST_TMP/dep-a/log"; echo "FAIL deposits.csv: a deposit the file lacked"; deposits_ok=0; fi
((deposits_ok)) || status=1

# ccs-backup-receive (the backup machine): proposals.csv, every version kept; deposits.csv, one
# copy, replaced only by one that has all its deposits; anything else refused
# (a host script: not in the image, which has no du, head, comm or sort; skipped there)
if ! type -P du head comm sort > /dev/null; then
    echo "ok   backup receiver: skipped (a host script, its tools are not in the image)"
else
    bk=$TEST_TMP/backup; mkdir -p "$bk"
    recv() { CCS_BACKUP_DIR=$bk "$here/../contrib/ccs-backup-receive" > "$TEST_TMP/recv.out" 2>&1; }
    d1=$TEST_TMP/dep-a/state/deposits.csv
    if recv < "$TEST_TMP/state/proposals.csv" && recv < "$d1" && [[ $(find "$bk" -name 'proposals-*.csv' | wc -l) == 1 ]] && cmp -s "$d1" "$bk/deposits.csv" \
        && { sed '1s/checked [0-9]*/checked 1/' "$d1"; printf '3099999,%064d,1,5,0\n' 7; } | recv && [[ $(wc -l < "$bk/deposits.csv") == $(($(wc -l < "$d1") + 1)) ]] \
        && ! sed '$d' "$d1" | recv && grep -q 'lacks 2 deposit' "$TEST_TMP/recv.out" \
        && ! printf '# final 1 checked 1\n1,zz,1,1,0\n' | recv && grep -q 'not a deposits.csv' "$TEST_TMP/recv.out" \
        && ! printf 'hello\n' | recv && [[ $(find "$bk" -name 'proposals-*.csv' | wc -l) == 1 ]]; then
        echo "ok   backup: proposals.csv kept as a new copy; deposits.csv one copy, replaced only by one with all its deposits; anything else refused"
    else
        cat "$TEST_TMP/recv.out"; ls -la "$bk"; echo "FAIL backup receiver"; status=1
    fi
fi

# contrib/migrate/compare-deposits: ccs-back's deposits table against the first run's deposits.csv.
# The same deposits: OK. One ccs-back has and the wallet doesn't, or another amount: NOT OK (exit 1).
# One only the wallet has (time-locked: ccs-back skipped it) is listed with why. Blocks past the
# file's height, the pool and subaddress 0 aren't compared.
# (a host script, like ccs-backup-receive: skipped in the image, which lacks its tools)
if ! type -P sort comm join head tail > /dev/null; then
    echo "ok   compare-deposits: skipped (a host script, its tools are not in the image)"
else
    cmpd=$here/../contrib/migrate/compare-deposits dep=$TEST_TMP/dep-a/state/deposits.csv
    tail -n +2 "$dep" | awk -F, '$5 == 0 { printf "%s\t%s\t%s\t%s\n", $2, $3, $4, $1 }' > "$TEST_TMP/ccs-back.tsv"
    printf '%064d\t1\t5\t0\n%064d\t0\t5\t3099900\n%064d\t1\t5\t3100000\n' 1 2 3 >> "$TEST_TMP/ccs-back.tsv"   # pool, subaddress 0, newer: not compared
    if "$cmpd" "$TEST_TMP/ccs-back.tsv" "$dep" > "$TEST_TMP/cmp.out" && grep -q '^OK' "$TEST_TMP/cmp.out" \
        && grep -q 'time-locked: ccs-back skipped it while locked' "$TEST_TMP/cmp.out"; then
        cp "$TEST_TMP/ccs-back.tsv" "$TEST_TMP/ccs-back-more.tsv"
        printf '%064d\t2\t70000\t3099000\n' 9 >> "$TEST_TMP/ccs-back-more.tsv"
        sed -i '1s/\t[0-9]*\t/\t1\t/; 1s/\t\([0-9]*\)\t\([0-9]*\)$/\t1\1\t\2/' "$TEST_TMP/ccs-back-more.tsv"
        if ! "$cmpd" "$TEST_TMP/ccs-back-more.tsv" "$dep" > "$TEST_TMP/cmp.out" && grep -q "NOT OK: 1 deposit(s) ccs-back recorded that the wallet doesn't have" "$TEST_TMP/cmp.out" \
            && grep -q 'NOT OK: 1 deposit(s) with another amount' "$TEST_TMP/cmp.out"; then
            echo "ok   compare-deposits: ccs-back's deposits are the wallet's: OK; one it lacks, or another amount: NOT OK"
        else cat "$TEST_TMP/cmp.out"; echo "FAIL compare-deposits: differences"; status=1; fi
    else cat "$TEST_TMP/cmp.out"; echo "FAIL compare-deposits: the same deposits"; status=1; fi
    # a deposits.csv line hiding a command in a field (it runs as root): refused, nothing run
    bad=$TEST_TMP/deposits-bad.csv
    { head -n 1 "$dep"; printf '3099901,%064d,1,BASH_VERSINFO[$(touch${IFS}%s)],0\n' 7 "$TEST_TMP/pwned"; } > "$bad"
    if ! "$cmpd" "$TEST_TMP/ccs-back.tsv" "$bad" > "$TEST_TMP/cmp.out" 2>&1 && [[ ! -e $TEST_TMP/pwned ]] \
        && grep -q "a line that isn't" "$TEST_TMP/cmp.out"; then
        echo "ok   compare-deposits: a deposits.csv line that isn't digits and a txid is refused, nothing in it run"
    else cat "$TEST_TMP/cmp.out"; echo "FAIL compare-deposits: a hostile deposits.csv line"; status=1; fi
fi

# reactions that can't be read: the idea stays, without counts
got=$(
    # shellcheck source=tests/stubs.sh
    source "$here/stubs.sh"
    WORK=$(mktemp -d) REPOSITORY_URL=https://forgejo.invalid/api/v1/repos/monero/ccs-proposals PROPOSALS_DIR=$FIXTURES/proposals TEST_FAIL_VOTES=11 \
        ideas 2> /dev/null | jq -c 'map([.upvotes, .downvotes])'
)
if [[ $got == '[[1,0],[null,null]]' ]]; then echo "ok   unreadable reactions leave the idea, without counts"; else echo "FAIL unreadable reactions: $got"; status=1; fi

# release/verify: only TRUSTED_KEYS' attesters count; without it nothing does, unless --any-key
# (anyone can send ccs-sigs a key). A ccs-sigs of one release attested by one test key.
if command -v gpg > /dev/null && command -v gpgconf > /dev/null; then
    sigs=$TEST_TMP/sigs k=$TEST_TMP/gpg
    mkdir -p "$sigs/builder-keys" "$sigs/ccs-bash-v9.9.9/alice" && mkdir -m 700 "$k"
    GNUPGHOME=$k gpg --batch --quiet --passphrase '' --quick-gen-key 'alice <alice@test>' ed25519 sign 1d 2> /dev/null
    fpr=$(GNUPGHOME=$k gpg --with-colons -K 2> /dev/null | awk -F: '$1 == "fpr" { print $10; exit }')
    GNUPGHOME=$k gpg --batch --armor --export "$fpr" > "$sigs/builder-keys/alice.asc"
    printf '%064d  ccs-bash-v9.9.9-%040d.image-id\n' 1 2 > "$sigs/ccs-bash-v9.9.9/alice/all.SHA256SUMS"
    GNUPGHOME=$k gpg --batch --quiet --armor --detach-sign "$sigs/ccs-bash-v9.9.9/alice/all.SHA256SUMS"
    GNUPGHOME=$k gpgconf --kill all 2> /dev/null || true
    echo "$fpr  # alice" > "$TEST_TMP/verify-trusted" && echo "${fpr//?/0}" > "$TEST_TMP/verify-stranger"
    v() { env CCS_SIGS_REPO="$sigs" "$@" "$here/../contrib/release/verify" --min-signers 1 ccs-bash-v9.9.9 > "$TEST_TMP/v.out" 2>&1; }
    if ! v && grep -q 'ERR: set TRUSTED_KEYS' "$TEST_TMP/v.out" \
        && v TRUSTED_KEYS="$TEST_TMP/verify-trusted" && grep -q '(1 signer(s) agree)' "$TEST_TMP/v.out" \
        && ! v TRUSTED_KEYS="$TEST_TMP/verify-stranger" && grep -q 'by no one in TRUSTED_KEYS' "$TEST_TMP/v.out" \
        && env CCS_SIGS_REPO="$sigs" "$here/../contrib/release/verify" --any-key --min-signers 1 ccs-bash-v9.9.9 > /dev/null 2>&1; then
        echo "ok   release/verify: only trusted keys count; none set, nothing counts but with --any-key"
    else
        cat "$TEST_TMP/v.out"; echo "FAIL release/verify and TRUSTED_KEYS"; status=1
    fi
else
    echo "ok   release/verify: skipped (no gpg here)"
fi

for f in proposals.json completed-proposals.json projects.json proposals.csv log; do
    if diff -u "$here/expected/$f" "$TEST_TMP/out/$f"; then echo "ok   $f"; else echo "FAIL $f"; status=1; fi
done
exit "$status"

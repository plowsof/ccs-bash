#!/usr/bin/env bash
# tests/regtest.sh: ccs-back.sh and ccs-front-bash against a real monerod (regtest, offline) and
# real monero-wallet-rpc: a funder wallet sends the donations, ccs-bash reads a view-only copy of
# a fresh CCS wallet (lookahead 1:1, as docs/handover.md step 1 says), ccs-front-bash makes the
# site, and what a visitor sees (each proposal's donate box, the Funding Required cards,
# /projects) is checked against what the test itself sent, in atomic units. Only the forge is a
# stub (no ideas). Prints an ok/FAIL line a check, exits 1 if any failed.
#
#   tests/regtest.sh
#   KEEP=1            keep the temporary folder (printed at the end)
#   REGTEST_CACHE     where the Monero tarballs and the design's zip are kept
#                     (default ${XDG_CACHE_HOME:-~/.cache}/ccs-regtest)
#   FRONT_BASH        a ccs-front-bash checkout (default: ../ccs-front-bash beside this repository)
#   HUGO_ZIP          ccs-front-hugo's release zip (default: v0.1.24, downloaded and checked)
#   REGTEST_PORT      first of the 127.0.0.1 ports used (default 38180; up to +20)
#   OLD_MONERO=0      skip the time-locked scenario (it needs v0.18.3.3's monerod and wallet-rpc:
#                     since v0.18.3.4 the wallet refuses an unlock_time and the pool rejects one)
#
# Needs bash, curl, jq, git, unzip, qrencode (ccs-front-bash), bzip2, sha256sum. No network but
# the downloads (once, cached); every daemon and wallet listens on 127.0.0.1 only.
set -euo pipefail
export LC_ALL=C TZ=UTC
here=$(dirname "$(readlink -f "$0")")
repo=${here%/tests}
CACHE=${REGTEST_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/ccs-regtest}
FRONT=${FRONT_BASH:-$repo/../ccs-front-bash}
PORT=${REGTEST_PORT:-38180}
MONERO_V=v0.18.5.4
MONERO_SHA=ba2928962c101b609434bf8c1b43ad59ebe96c5525977284ca599d8bf0f02d10
# (binaryFate's signed hashes.txt for v0.18.3.3, monero-site commit d00169a6d)
OLD_V=v0.18.3.3
OLD_SHA=47c7e6b4b88a57205800a2538065a7874174cd087eedc2526bee1ebcce0cc5e3
HUGO_V=v0.1.24
HUGO_SHA=ade9543a37da7df5bd06c396e2d3d8583db44d4d4754fcbd2a8d5e687f85dc4e
RPC_PW=regtest-rpc-pw
WALLET_PW=regtest-wallet-pw

T=$(mktemp -d "${TMPDIR:-/tmp}/ccs-regtest.XXXXXX")
PIDS=()
cleanup() {
    local p
    for p in "${PIDS[@]}"; do kill "$p" 2> /dev/null || true; done
    for p in "${PIDS[@]}"; do wait "$p" 2> /dev/null || true; done
    if [[ ${KEEP:-} ]]; then echo "kept $T"; else rm -rf "$T"; fi
}
trap cleanup EXIT

RESULTS=$T/results
: > "$RESULTS"
ok() { printf 'ok   %s\n' "$*" | tee -a "$RESULTS"; }
fail() { printf 'FAIL %s\n' "$*" | tee -a "$RESULTS"; }
note() { printf '     %s\n' "$*" | tee -a "$RESULTS"; }
check() { # check LABEL EXPECTED SHOWN
    if [[ $2 == "$3" ]]; then ok "$1: $3"; else fail "$1: expected '$2', shown '$3'"; fi
}
die() { echo "regtest: $*" >&2; exit 2; }

# ---- downloads, checked, cached outside the repository ----

fetch() { # fetch URL SHA256 -> the cached file's path
    local f=$CACHE/${1##*/}
    mkdir -p "$CACHE"
    if [[ ! -f $f ]] || ! sha256sum -c --status <<<"$2  $f"; then
        curl -fsSL -o "$f.part" "$1" || die "could not download $1"
        mv "$f.part" "$f"
    fi
    sha256sum -c --status <<<"$2  $f" || die "$f: sha256 is not $2"
    printf '%s\n' "$f"
}

monero_bins() { # monero_bins VERSION SHA DIR: monerod and monero-wallet-rpc into DIR
    local tb
    tb=$(fetch "https://downloads.getmonero.org/cli/monero-linux-x64-$1.tar.bz2" "$2")
    mkdir -p "$3"
    tar -xjf "$tb" -C "$3" --strip-components=1 --wildcards '*/monerod' '*/monero-wallet-rpc'
}

# ---- RPC ----

# call URL METHOD PARAMS [CURL OPTION...]: the result (jq -e: an error fails)
call() {
    local out
    out=$(curl -fsS --max-time 300 "${@:4}" -H 'Content-Type: application/json' \
        -d "{\"jsonrpc\":\"2.0\",\"id\":\"0\",\"method\":\"$2\",\"params\":$3}" "$1") || return 1
    jq -e '.result // error("\(.error.message // "no result")")' <<<"$out"
}
D() { call "http://127.0.0.1:$DPORT/json_rpc" "$1" "${2:-"{}"}"; }
Dother() { curl -fsS --max-time 120 -H 'Content-Type: application/json' -d "${2:-"{}"}" "http://127.0.0.1:$DPORT/$1"; }
F() { call "http://127.0.0.1:$FPORT/json_rpc" "$1" "${2:-"{}"}"; }
K() { call "http://127.0.0.1:$KPORT/json_rpc" "$1" "${2:-"{}"}"; }
C() { call "http://127.0.0.1:$CPORT/json_rpc" "$1" "${2:-"{}"}" --digest -u "ccs:$RPC_PW"; }

wait_for() { # wait_for NAME COMMAND...: on as soon as it answers; at once if one started has died; else up to 3 minutes (a CI runner can be slow)
    local i p log why="did not start in 3 minutes"
    for ((i = 0; i < 720; i++)); do
        "${@:2}" > /dev/null 2>&1 && return 0
        for p in "${PIDS[@]}"; do kill -0 "$p" 2> /dev/null || { why="did not start: a daemon or wallet it needs exited"; break 2; }; done
        sleep 0.25
    done
    for log in "$T"/*/wallet-rpc.log "$T"/*/monerod.log "$T"/*/stdout "$T"/*/*/wallet-rpc.log "$T"/*/*/monerod.log "$T"/*/*/stdout; do
        [[ -f $log ]] && { echo "--- ${log#"$T"/}"; tail -n 5 "$log"; }
    done
    die "$1 $why"
}

start_daemon() { # start_daemon BIN DIR
    mkdir -p "$2"
    "$1/monerod" --regtest --offline --fixed-difficulty 1 --no-igd --non-interactive --data-dir "$2" \
        --rpc-bind-ip 127.0.0.1 --rpc-bind-port "$DPORT" --p2p-bind-ip 127.0.0.1 --p2p-bind-port "$((DPORT - 1))" \
        --zmq-rpc-bind-ip 127.0.0.1 --zmq-rpc-bind-port "$((DPORT + 1))" --log-file "$2/monerod.log" > "$2/stdout" 2>&1 &
    PIDS+=($!)
    wait_for monerod D get_info
}

start_wallet() { # start_wallet BIN PORT DIR [LOGIN]
    local auth=(--disable-rpc-login)
    [[ -z ${4:-} ]] || auth=(--rpc-login "$4")
    mkdir -p "$3"
    "$1/monero-wallet-rpc" --allow-mismatched-daemon-version --daemon-address "127.0.0.1:$DPORT" --trusted-daemon \
        --rpc-bind-ip 127.0.0.1 --rpc-bind-port "$2" "${auth[@]}" --wallet-dir "$3" --log-file "$3/wallet-rpc.log" \
        --non-interactive > "$3/stdout" 2>&1 &
    PIDS+=($!)
}

daemon_height() { D get_info | jq -r .height; }
mine() { # mine N: N blocks, the coinbase to the funder
    D generateblocks "{\"amount_of_blocks\": $1, \"wallet_address\": \"$FUNDER\"}" > /dev/null
    F refresh > /dev/null
}

# The environment: monerod, the funder, the keys wallet (a full copy of the CCS wallet, for the
# published list of its subaddresses) and the CCS wallet: view-only, from its address and view
# key, with lookahead 1:1, as production.
setup_env() { # setup_env BIN FUNDER_BIN DIR
    local bin=$1 fbin=$2 dir=$3 vk
    start_daemon "$bin" "$dir/monerod"
    start_wallet "$fbin" "$FPORT" "$dir/funder"
    start_wallet "$bin" "$KPORT" "$dir/keys"
    start_wallet "$bin" "$CPORT" "$dir/ccs" "ccs:$RPC_PW"
    wait_for funder F get_version
    wait_for "keys wallet" K get_version
    wait_for "ccs wallet" C get_version
    F create_wallet '{"filename": "funder", "password": "", "language": "English"}' > /dev/null
    F auto_refresh '{"enable": false}' > /dev/null || true
    FUNDER=$(F get_address | jq -r .address)
    K create_wallet '{"filename": "ccs-full", "password": "", "language": "English"}' > /dev/null
    CCS_ADDRESS=$(K get_address | jq -r .address)
    vk=$(K query_key '{"key_type": "view_key"}' | jq -r .key)
    # the list a Core Team member would sign: subaddresses 0..250 of account 0, and (1, 0)
    K create_address '{"account_index": 0, "count": 250}' > /dev/null
    K get_address '{"account_index": 0}' | jq -r '.addresses[] | "\(.address_index) \(.address)"' > "$dir/list"
    K create_account > /dev/null
    K get_address '{"account_index": 1}' | jq -r '.addresses[0] | "acct1 \(.address)"' >> "$dir/list"
    LIST=$dir/list
    C generate_from_keys "{\"filename\": \"ccs\", \"address\": \"$CCS_ADDRESS\", \"viewkey\": \"$vk\", \"password\": \"$WALLET_PW\", \"restore_height\": 0}" > /dev/null
    C set_subaddress_lookahead "{\"password\": \"$WALLET_PW\", \"major_idx\": 1, \"minor_idx\": 1}" > /dev/null
    C auto_refresh '{"enable": false}' > /dev/null
    CCS_CACHE=$dir/ccs/ccs
}

addr_of() { awk -v i="$1" '$1 == i { print $2; exit }' "$LIST"; }
idx_of() { awk -v a="$1" '$2 == a { print $1; exit }' "$LIST"; }

# ---- the proposals and ccs-bash ----

proposal() { # proposal FILE TITLE AMOUNT
    cat > "$PROPOSALS/$1" <<EOF
---
layout: fr
title: "$2"
author: regtest
date: October 1, 2026
amount: $3
milestones:
  - name: One
    done:
payouts:
---
Regtest proposal $2.
EOF
    git -C "$PROPOSALS" add "$1" && git -C "$PROPOSALS" -c user.name=regtest -c user.email=regtest@invalid commit -qm "$1"
}

write_conf() { # write_conf FILE STATE OUT MIN_CONFIRMATIONS
    [[ ! -f $1 ]] || chmod 644 "$1"
    cat > "$1" <<EOF
RPC_URL=http://127.0.0.1:$CPORT/json_rpc
RPC_USER=ccs
RPC_PASSWORD=$RPC_PW
WALLET_ADDRESS=$CCS_ADDRESS
REPOSITORY_URL=https://forge.invalid/api/v4/projects/1
PROPOSALS_DIR=$PROPOSALS
STATE_DIR=$2
OUTPUT_DIR=$3
MIN_CONFIRMATIONS=$4
EOF
    chmod 444 "$1"   # not writable, like the root-owned config ccs-bash insists on
    mkdir -p "$2" "$3"
    [[ -e $2/proposals.csv ]] || : > "$2/proposals.csv"
}

# run_back [CONF]: the wallet refreshed (auto-refresh is off, so a check sees a known height),
# then ccs-back.sh in its own bash, the forge a stub: no MRs. Its time in LAST_SECONDS.
run_back() {
    local conf=${1:-$CONF} t0 t1 rc=0 wh dh
    C refresh > /dev/null
    wh=$(C get_height | jq -r .height) dh=$(daemon_height)
    [[ $wh == "$dh" ]] || die "the ccs wallet is at $wh, monerod at $dh"
    t0=$(date +%s.%N)
    # shellcheck disable=SC2016
    bash -c 'source "$1" && gitlab_get() { echo "[]"; } && main "$2"' _ "$repo/ccs-back.sh" "$conf" 2> "$T/last.log" || rc=$?
    t1=$(date +%s.%N)
    LAST_SECONDS=$(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.2f", b - a }')
    cat "$T/last.log" >> "$T/ccs-back.log"
    return "$rc"
}

# run_front [OUT] [SITE]: ccs-front-bash, the site into SITE
run_front() {
    "$FRONT/ccs-front-bash.sh" "$HUGO" "${1:-$OUT}" "$PROPOSALS" "${2:-$SITE}" 2>> "$T/front.log"
}

update() { # update [CONF] [OUT] [SITE]: both, or a FAIL line
    if ! run_back "${1:-$CONF}"; then fail "ccs-back.sh stopped: $(grep -o 'error: .*' "$T/last.log" | head -1)"; return 1; fi
    run_front "${2:-$OUT}" "${3:-$SITE}" || { fail "ccs-front-bash failed: $(tail -1 "$T/front.log")"; return 1; }
}

# ---- what a visitor sees ----

page_address() { sed -n 's:.*<div class="address">\([0-9A-Za-z]*\)</div>.*:\1:p' "${2:-$SITE}/proposals/${1%.md}.html" | head -1; }
page_raised() { # the donate box's line, tags removed
    grep -o '<p class="progress-label">Raised <strong>[^<]*</strong> of [^<]*</p>' "${2:-$SITE}/proposals/${1%.md}.html" \
        | sed 's/<[^>]*>//g' | head -1
}
card() { # the Funding Required card: "N contributors|Raised ..."
    awk -v href="proposals/${1%.md}.html\"" '
        index($0, "<a class=\"card fr\"") && index($0, href) { on = 1 }
        on && /contributors<\/li>/ { sub(/<\/li>.*/, ""); c = $0 }
        on && /class="progress-label"/ { sub(/.*<p class="progress-label">/, ""); sub(/<\/p>.*/, ""); r = $0 }
        on && /<\/a>/ { on = 0; print c "|" r; exit }' "${2:-$SITE}/funding-required/index.html"
}
project() { # /projects: raised_amount (in ten-thousandths of an XMR: the same whether a number
    # or text) contributions percentage_funded
    jq -r --arg f "$1" '.[] | select(.filename == $f) | "\(.raised_amount | tonumber * 10000 | round) \(.contributions) \(.percentage_funded)"' "${2:-$OUT}/projects.json"
}

# ---- the expected numbers, from what was sent ----
# LEDGER: one line per output sent: txid idx amount before unlock
#   idx: the subaddress (or acct1, or none); before: 1 if no proposal showed that subaddress when
#   it was sent (not any proposal's money); unlock: the tx's unlock_time
LEDGER=$T/ledger
: > "$LEDGER"
SHOWN=" "   # subaddresses some proposal's page shows

send() { # send [unlock=N] IDX:AMOUNT...: one transfer_split; the txids
    local unlock=0 d dests='' res txid
    if [[ $1 == unlock=* ]]; then unlock=${1#unlock=}; shift; fi
    for d in "$@"; do
        dests+="${dests:+,}{\"address\": \"$(addr_of "${d%%:*}")\", \"amount\": ${d#*:}}"
    done
    local params="{\"destinations\": [$dests], \"account_index\": 0, \"priority\": 0"
    ((unlock == 0)) || params+=", \"unlock_time\": $unlock"
    res=$(F transfer_split "$params}") || return 1
    for txid in $(jq -r '.tx_hash_list[]' <<<"$res"); do
        F get_transfer_by_txid "{\"txid\": \"$txid\"}" | jq -r '.transfer.destinations[] | "\(.address) \(.amount)"' |
            while read -r a amount; do
                local i
                i=$(idx_of "$a"); i=${i:-none}
                printf '%s %s %s %s %s\n' "$txid" "$i" "$amount" "$([[ $SHOWN == *" $i "* ]] && echo 0 || echo 1)" "$unlock"
            done >> "$LEDGER"
        printf '%s\n' "$txid"
    done
}

# expect IDX MIN: "raised pending count" (atomic units) a proposal at subaddress IDX should show,
# from the ledger and where each tx is now (monerod): in a block MIN deep, raised; in the pool or
# less deep, pending; time-locked, nothing until unlocked; gone (a reorg), nothing. A count is a
# (tx, subaddress), as ccs-back's deposits table: two outputs of one tx to one proposal are one.
expect() {
    local idx=$1 min=$2 dh txid i amount before unlock raised=0 pending=0 st h
    local -A seen=() where=() height=()
    dh=$(daemon_height)
    local hashes
    hashes=$(awk -v i="$idx" '$2 == i { print $1 }' "$LEDGER" | jq -R . | jq -sc 'unique')
    while read -r txid st h; do where[$txid]=$st height[$txid]=$h; done < <(
        Dother get_transactions "{\"txs_hashes\": $hashes}" \
            | jq -r '(.txs // [])[] | "\(.tx_hash) \(if .in_pool then "pool" else "block" end) \(.block_height)"')
    while read -r txid i amount before unlock; do
        [[ $i == "$idx" && $before == 0 && -n ${where[$txid]:-} ]] || continue
        ((${#unlock} <= 18)) || continue   # (past 18 digits: locked for good, and bash would wrap it)
        if ((unlock > 0)); then
            if ((unlock < 500000000)); then ((dh >= unlock)) || continue; else (($(date +%s) >= unlock)) || continue; fi
        fi
        if [[ ${where[$txid]} == pool ]] || ((dh - height[$txid] < min)); then
            pending=$((pending + amount))
        else
            raised=$((raised + amount))
        fi
        seen[$txid]=1
    done < "$LEDGER"
    printf '%s %s %s\n' "$raised" "$pending" "${#seen[@]}"
}

xmr4() { printf '%d.%04d' $(($1 / 1000000000000)) $(($1 % 1000000000000 / 100000000)); }
trim0() { local x=$1; if [[ $x == *.* ]]; then while [[ $x == *0 ]]; do x=${x%0}; done; x=${x%.}; fi; printf '%s' "$x"; }

declare -A TARGET=()   # file -> atomic units
declare -A IDX=()      # file -> subaddress shown on its page

# shows LABEL FILE [MIN] [OUT] [SITE]: the donate box, the card and /projects against expect
shows() {
    local label=$1 f=$2 min=${3:-10} out=${4:-$OUT} site=${5:-$SITE} r p n note want pct
    read -r r p n < <(expect "${IDX[$f]}" "$min")
    note=''
    ((p == 0)) || note=" · $(trim0 "$(xmr4 "$p")") XMR pending"
    want="Raised $(trim0 "$(xmr4 "$r")") of $(trim0 "$(xmr4 "${TARGET[$f]}")") XMR$note"
    pct=$((r * 100 / TARGET[$f])); ((pct <= 100)) || pct=100
    local got_page got_card got_proj
    got_page=$(page_raised "$f" "$site")
    got_card=$(card "$f" "$site")
    got_proj=$(project "$f" "$out")
    if [[ $got_page == "$want" && $got_card == "$n contributors|$want" && $got_proj == "$((r / 100000000)) $n $pct" ]]; then
        ok "$label: $f: \"$want\", $n contributors, /projects $got_proj"
    else
        fail "$label: $f: expected \"$want\", $n contributors, /projects $(xmr4 "$r") $n $pct; shown: page \"$got_page\", card \"$got_card\", /projects $got_proj"
    fi
}

all_show() { local f; for f in "${!IDX[@]}"; do shows "$1" "$f" "${2:-10}"; done; }

# the subaddress each fr proposal's page shows, checked against the published list
read_addresses() {
    local f a i
    for f in "${!TARGET[@]}"; do
        a=$(page_address "$f")
        i=$(idx_of "$a")
        [[ -n $a && -n $i && $i != 0 && $i != acct1 ]] || { fail "$f: its page shows no address of the CCS wallet ('$a')"; continue; }
        IDX[$f]=$i
        [[ $SHOWN == *" $i "* ]] || SHOWN+="$i "
    done
}

labels() { C get_address '{"account_index": 0}' | jq '.addresses | length'; }
cache_bytes() { C store > /dev/null; stat -c %s "$CCS_CACHE"; }

# =================================================================================================

[[ -x $FRONT/ccs-front-bash.sh ]] || die "no ccs-front-bash at $FRONT (FRONT_BASH=)"
monero_bins "$MONERO_V" "$MONERO_SHA" "$T/bin"
HUGO=$T/hugo
mkdir -p "$HUGO"
unzip -q "${HUGO_ZIP:-$(fetch "https://github.com/plowsof/ccs-front-hugo/releases/download/$HUGO_V/ccs-front-hugo-$HUGO_V.zip" "$HUGO_SHA")}" -d "$HUGO"

DPORT=$((PORT + 1)) FPORT=$((PORT + 3)) KPORT=$((PORT + 4)) CPORT=$((PORT + 5))
setup_env "$T/bin" "$T/bin" "$T/main"
# coinbase to the funder: 400 blocks, unlocked after 60
mine 400
if C query_key '{"key_type": "spend_key"}' > /dev/null 2>&1; then fail "the CCS wallet can spend (not view-only)"; else ok "setup: the CCS wallet is view-only, lookahead 1:1, monerod $MONERO_V regtest"; fi

PROPOSALS=$T/proposals
git init -q "$PROPOSALS"
proposal p-alpha.md "Alpha" "100 XMR"
proposal p-beta.md "Beta" "50.5 XMR"
proposal p-gamma.md "Gamma" "12 XMR"
TARGET[p-alpha.md]=100000000000000 TARGET[p-beta.md]=50500000000000 TARGET[p-gamma.md]=12000000000000
CONF=$T/ccs.conf STATE=$T/state OUT=$T/out SITE=$T/site
write_conf "$CONF" "$STATE" "$OUT" 10

# ---- 0. the first run: each proposal a subaddress, shown on its page ----
update
read_addresses
check "setup: subaddresses on the pages (alpha beta gamma)" "1 2 3" "${IDX[p-alpha.md]} ${IDX[p-beta.md]} ${IDX[p-gamma.md]}"
all_show "setup, nothing sent"

# ---- 1. one tx, two outputs to two proposals ----
send "${IDX[p-alpha.md]}:1500000000000" "${IDX[p-beta.md]}:250000000000" > /dev/null
mine 10
update
shows "1. one tx to two proposals" p-alpha.md
shows "1. one tx to two proposals" p-beta.md

# ---- 2. one tx, two outputs to the same proposal ----
send "${IDX[p-gamma.md]}:300000000000" "${IDX[p-gamma.md]}:400000000000" > /dev/null
mine 10
update
shows "2. one tx, two outputs to one proposal (counted once: a donation is a tx)" p-gamma.md
note "2. the wallet's get_transfers gives one entry per (tx, subaddress), amounts summed: $(C get_transfers "{\"in\": true, \"account_index\": 0, \"subaddr_indices\": [${IDX[p-gamma.md]}]}" | jq '.in | length') entry for 2 outputs"

# ---- 3. pending: the pool, then 1..9 confirmations, then 10 ----
send "${IDX[p-alpha.md]}:123000000000" > /dev/null
update; shows "3. in the pool: pending only" p-alpha.md
mine 1; update; shows "3. 1 confirmation: pending only" p-alpha.md
mine 8; update; shows "3. 9 confirmations: pending only" p-alpha.md
mine 1; update; shows "3. 10 confirmations: raised" p-alpha.md
# a tx that leaves the pool unmined: its pending note and count go again (documented)
tx=$(send "${IDX[p-beta.md]}:777000000000")
update; shows "3. a second tx in the pool" p-beta.md
D flush_txpool "{\"txids\": [\"$tx\"]}" > /dev/null
update; shows "3. that tx dropped from the pool (pending gone, count back)" p-beta.md
# MIN_CONFIRMATIONS=1 (the testnet's), on a copy of the state
cp -r "$STATE" "$T/state1"; cp -r "$OUT" "$T/out1"
write_conf "$T/ccs1.conf" "$T/state1" "$T/out1" 1
send "${IDX[p-beta.md]}:20000000000" > /dev/null
update "$T/ccs1.conf" "$T/out1" "$T/site1" && shows "3. MIN_CONFIRMATIONS=1, in the pool" p-beta.md 1 "$T/out1" "$T/site1"
mine 1
update "$T/ccs1.conf" "$T/out1" "$T/site1" && shows "3. MIN_CONFIRMATIONS=1, 1 confirmation: raised" p-beta.md 1 "$T/out1" "$T/site1"
update; shows "3. MIN_CONFIRMATIONS=10 on the same chain, 1 confirmation: pending" p-beta.md
mine 9; update; all_show "3. after 10"

# ---- 5. spam: 100+ donations, quickly ----
spam=()
for ((k = 0; k < 104; k++)); do
    case $((k % 4)) in
        0) amount=1 ;;                                      # 1 piconero
        1) amount=$((k * 1000 + 7)) ;;                      # dust
        2) amount=$((k * 123456789)) ;;
        3) amount=$((k * 10000000000 + 1)) ;;
    esac
    names=(p-alpha.md p-beta.md p-gamma.md); to=${names[k % 3]}
    spam+=("${IDX[$to]}:$amount")
done
sent_txs=0
# 40 outputs in one call (several txs), 15 (one tx), then 1 to 6 outputs a tx
for tx in $(send "${spam[@]:0:40}"); do sent_txs=$((sent_txs + 1)); done
for tx in $(send "${spam[@]:40:15}"); do sent_txs=$((sent_txs + 1)); done
k=55
while ((k < ${#spam[@]})); do
    n=$((k % 6 + 1))
    for tx in $(send "${spam[@]:k:n}"); do sent_txs=$((sent_txs + 1)); done
    k=$((k + n))
done
note "5. ${#spam[@]} outputs sent in $sent_txs txs"
update; s_pool=$LAST_SECONDS
all_show "5. spam in the pool"
mine 10
update; s_conf=$LAST_SECONDS
all_show "5. spam, 10 confirmations"
mine 30
update; s_final=$LAST_SECONDS
all_show "5. spam, 40 confirmations (in deposits.csv)"
# deposits.csv: one line a (tx, subaddress) at least 30 deep, the amounts summed, none twice
final=$(sed -n 's/^# final \([0-9]*\) .*/\1/p' "$STATE/deposits.csv")
want_csv=$(Dother get_transactions "{\"txs_hashes\": $(cut -d' ' -f1 "$LEDGER" | jq -R . | jq -sc unique)}" \
    | jq -r --argjson f "$final" '(.txs // [])[] | select(.in_pool | not) | select(.block_height <= $f) | "\(.tx_hash) \(.block_height)"' \
    | awk 'NR == FNR { h[$1] = $2; next } ($1 in h) && $2 ~ /^[0-9]+$/ && $2 != 0 { s[h[$1] "," $1 "," $2] += $3 } END { for (k in s) printf "%s,%d,%d\n", k, s[k], 0 }' - "$LEDGER" | sort)
got_csv=$(awk 'NR > 1' "$STATE/deposits.csv" | sort)
if [[ $want_csv == "$got_csv" ]]; then ok "5. deposits.csv: $(grep -c . <<<"$got_csv") deposits, each (tx, subaddress) once, amounts exact"
else fail "5. deposits.csv differs from what was sent: $(diff <(echo "$want_csv") <(echo "$got_csv") | grep -c '^[<>]') lines"; diff <(echo "$want_csv") <(echo "$got_csv") | head -5 | sed 's/^/     /'; fi
# a full recount (deposits.csv deleted) gives the same
cp "$OUT/projects.json" "$T/projects-before-recount.json"
rm "$STATE/deposits.csv"
update; s_full=$LAST_SECONDS
if diff -q "$T/projects-before-recount.json" "$OUT/projects.json" > /dev/null && [[ $(awk 'NR > 1' "$STATE/deposits.csv" | sort) == "$got_csv" ]]; then
    ok "5. deposits.csv deleted: made again the same, the same totals"
else fail "5. deposits.csv deleted: different totals or file"; fi
note "5. ccs-back.sh run time with $(grep -c . <<<"$got_csv") deposits: pool ${s_pool}s, 10 conf ${s_conf}s, incremental ${s_final}s, full recount ${s_full}s"

# ---- 6. subaddresses no proposal was given: lookahead, cache growth, dust before hand-out ----
before_labels=$(labels) before_bytes=$(cache_bytes)
next=$before_labels    # the next subaddress a proposal will get (published in the list)
note "6. the wallet has $before_labels subaddresses (0..$((next - 1))), cache $before_bytes bytes"
send "$next:5000" > /dev/null
mine 10; update
l1=$(labels) b1=$(cache_bytes)
note "6. dust to $next (the next one, within the lookahead): wallet $l1 subaddresses, cache +$((b1 - before_bytes)) bytes"
if grep -q "warning: donations at subaddress $next, which no proposal was given" "$T/last.log"; then
    ok "6. dust to $next: logged, counted for no proposal"; else fail "6. dust to $next: not logged as no proposal's"; fi
all_show "6. dust to $next"
beyond=$((next + 2))
send "$beyond:6000" > /dev/null
mine 10; update
l2=$(labels) b2=$(cache_bytes)
at_beyond=$(C get_transfers "{\"in\": true, \"account_index\": 0, \"subaddr_indices\": [$beyond]}" | jq -c '.in // [] | length')
note "6. dust to $beyond (past the lookahead of 1): wallet $l2 subaddresses, cache +$((b2 - b1)) bytes, the wallet's transfers at $beyond: $at_beyond (generate_from_keys built the default 50x200 scan table; set_subaddress_lookahead 1:1 doesn't shrink it)"
all_show "6. dust to $beyond"
far=240
send "$far:7000" > /dev/null
mine 10; update
l3=$(labels) b3=$(cache_bytes)
note "6. dust to $far (past the scan table): wallet $l3 subaddresses, cache +$((b3 - b2)) bytes, seen by the wallet: $(C get_transfers '{"in": true, "all_accounts": true}' | jq --argjson i "$far" '[.in[] | select(.subaddr_index.minor == $i)] | length')"

# new proposals get the next subaddresses: those with dust from before (the next one, and one
# past the lookahead, which the wallet didn't count as created) must not show it
state_max=$(jq -R -s 'split("\n") | map(select(. != "") | split(",")[2] | gsub("\""; "") | select(. != "") | tonumber) | max' "$STATE/proposals.csv")
note "6. the state's highest subaddress: $state_max; dust sat at $next and $beyond"
proposal p-delta.md "Delta" "10 XMR"
proposal p-eps.md "Epsilon" "10 XMR"
proposal p-zeta.md "Zeta" "10 XMR"
TARGET[p-delta.md]=10000000000000 TARGET[p-eps.md]=10000000000000 TARGET[p-zeta.md]=10000000000000
update
read_addresses
check "6. new proposals get the subaddresses after the state's highest (delta eps zeta)" "$((state_max + 1)) $((state_max + 2)) $((state_max + 3))" "${IDX[p-delta.md]} ${IDX[p-eps.md]} ${IDX[p-zeta.md]}"
note "6. assigned.tsv after the hand-out (height $(daemon_height)): $(tr '\t\n' ' ;' 2> /dev/null < "$STATE/assigned.tsv" || echo none)"
# donors who see the new addresses donate at once: mined in the next block
send "${IDX[p-delta.md]}:2000000000000" "${IDX[p-eps.md]}:3000000000000" > /dev/null
mine 1; update
shows "6. delta (dust at its subaddress before its hand-out; a donation in the next block, pending)" p-delta.md
shows "6. zeta (dust before its hand-out, past the lookahead)" p-zeta.md
mine 10; update
shows "6. delta (dust before; a donation mined in the first block after its hand-out)" p-delta.md
shows "6. eps (no dust before; a donation in the first block after its hand-out)" p-eps.md
shows "6. zeta, later" p-zeta.md

# growth: 10 txs, each dust to the then-next index
g0=$(labels) gb0=$(cache_bytes)
for ((k = 0; k < 10; k++)); do send "$(labels):1000" > /dev/null; mine 1; C refresh > /dev/null; done
g1=$(labels) gb1=$(cache_bytes)
note "6. 10 txs each to the next subaddress: wallet $g0 -> $g1 subaddresses, cache $gb0 -> $gb1 bytes ($(((gb1 - gb0) / 10)) a payment)"
# one tx, 15 outputs to the next 15 indices
# shellcheck disable=SC2046
send $(for ((k = 0; k < 15; k++)); do printf '%s:1000 ' $((g1 + k)); done) > /dev/null
mine 1; C refresh > /dev/null
g2=$(labels) gb2=$(cache_bytes)
note "6. 1 tx with 15 outputs to the next 15: wallet $g1 -> $g2 subaddresses, cache +$((gb2 - gb1)) bytes"
# 10 txs of dust to one subaddress already handed out (alpha's): cache growth alone
gb3=$(cache_bytes)
for ((k = 0; k < 10; k++)); do send "${IDX[p-alpha.md]}:1" > /dev/null; done
mine 1; C refresh > /dev/null
gb4=$(cache_bytes)
note "6. 10 txs of 1 piconero to alpha's subaddress: cache +$((gb4 - gb3)) bytes ($(((gb4 - gb3) / 10)) a payment; no lookahead bounds this)"
mine 9; update
all_show "6. after the growth payments"

# ---- 8. other things a donor can do ----
cp "$OUT/projects.json" "$T/projects-8.json"
send 0:3000000000 > /dev/null              # the main address
send acct1:4000000000 > /dev/null          # account 1's address (the wallet scans 50 accounts)
mine 10; update
if diff -q "$T/projects-8.json" "$OUT/projects.json" > /dev/null; then ok "8. to the main address and to account 1: on no proposal"; else fail "8. to the main address or account 1: a proposal changed"; fi

# ---- 7. never lower: a reorg ----
# a. a block with a deposit popped, its tx gone, a longer chain: raised would go down
tx=$(send "${IDX[p-beta.md]}:500000000000")
mine 10; update; shows "7. before the reorg" p-beta.md
cp -r "$OUT" "$T/out-7a"; cp -r "$SITE" "$T/site-7a"
Dother pop_blocks '{"nblocks": 10}' > /dev/null
D flush_txpool "{\"txids\": [\"$tx\"]}" > /dev/null
mine 12
if run_back; then
    fail "7. a reorg took away a counted deposit: the run went on ($(project p-beta.md))"
else
    if grep -q "would show less raised than before" "$T/last.log" && diff -rq "$T/out-7a" "$OUT" > /dev/null; then
        ok "7. a reorg took away a counted deposit: the run stops, the site keeps its last totals ($(project p-beta.md))"
    else fail "7. a reorg: the run stopped for another reason: $(grep -o 'error: .*' "$T/last.log" | head -1)"; fi
fi
touch "$STATE/allow-lower"
update && shows "7. allow-lower: the lower total, once" p-beta.md
# b. deeper than deposits.csv's 30: kept until the daily recount, which stops
tx=$(send "${IDX[p-gamma.md]}:900000000000")
mine 40; update; shows "7. before a 40-block reorg" p-gamma.md
shown_before=$(project p-gamma.md)
Dother pop_blocks '{"nblocks": 40}' > /dev/null
D flush_txpool "{\"txids\": [\"$tx\"]}" > /dev/null
mine 45
if update; then
    if [[ $(project p-gamma.md) == "$shown_before" ]]; then
        ok "7. a 40-block reorg (past deposits.csv): the kept deposit still shows until the daily recount ($shown_before; the chain has $(read -r r _ _ < <(expect "${IDX[p-gamma.md]}" 10); xmr4 "$r"))"
    else fail "7. a 40-block reorg: gamma shows $(project p-gamma.md), was $shown_before"; fi
fi
# the daily recount: deposits.csv's "checked" a day old
sed -i '1s/checked [0-9]*/checked 1/' "$STATE/deposits.csv"
if run_back; then fail "7. the daily recount after a 40-block reorg: the run went on"
elif grep -q "the wallet lacks 1 of the deposits kept" "$T/last.log"; then ok "7. the daily recount after a 40-block reorg: the run stops (the wallet lacks 1 of the kept deposits)"
else fail "7. the daily recount: stopped for another reason: $(grep -o 'error: .*' "$T/last.log" | head -1)"; fi
rm "$STATE/deposits.csv"; touch "$STATE/allow-lower"
update && shows "7. deposits.csv deleted, allow-lower: the chain's total" p-gamma.md

# ---- 8. a donation past 2^53 atomic units (9007.2 XMR) in one tx to one subaddress ----
F sweep_all "{\"address\": \"$FUNDER\", \"account_index\": 0}" > /dev/null
mine 11
send "${IDX[p-alpha.md]}:9008000000000000" > /dev/null
mine 10
cp -r "$OUT" "$T/out-8"
if run_back; then
    ok "8. a 9008 XMR donation: counted"
    run_front && shows "8. a 9008 XMR donation" p-alpha.md
else
    fail "8. a 9008 XMR donation stops every run: $(grep -m1 'error' "$T/last.log") (the site keeps its last totals)"
fi

# =================================================================================================
# ---- 4. time-locked donations (v0.18.3.3's monerod and funder: v0.18.3.4+ refuse unlock_time) ----
if [[ ${OLD_MONERO:-1} != 0 ]]; then
    for p in "${PIDS[@]}"; do kill "$p" 2> /dev/null || true; done
    for p in "${PIDS[@]}"; do wait "$p" 2> /dev/null || true; done
    PIDS=()
    monero_bins "$OLD_V" "$OLD_SHA" "$T/bin-old"
    DPORT=$((PORT + 11)) FPORT=$((PORT + 13)) KPORT=$((PORT + 14)) CPORT=$((PORT + 15))
    LEDGER=$T/ledger4; : > "$LEDGER"; SHOWN=" "
    # the old monerod and funder; the keys and CCS wallets are $MONERO_V's
    start_daemon "$T/bin-old" "$T/lock/monerod"
    start_wallet "$T/bin-old" "$FPORT" "$T/lock/funder"
    start_wallet "$T/bin" "$KPORT" "$T/lock/keys"
    start_wallet "$T/bin" "$CPORT" "$T/lock/ccs" "ccs:$RPC_PW"
    wait_for funder F get_version; wait_for "keys wallet" K get_version; wait_for "ccs wallet" C get_version
    F create_wallet '{"filename": "funder", "password": "", "language": "English"}' > /dev/null
    F auto_refresh '{"enable": false}' > /dev/null || true
    FUNDER=$(F get_address | jq -r .address)
    K create_wallet '{"filename": "ccs-full", "password": "", "language": "English"}' > /dev/null
    CCS_ADDRESS=$(K get_address | jq -r .address)
    vk=$(K query_key '{"key_type": "view_key"}' | jq -r .key)
    K create_address '{"account_index": 0, "count": 50}' > /dev/null
    K get_address '{"account_index": 0}' | jq -r '.addresses[] | "\(.address_index) \(.address)"' > "$T/lock/list"
    LIST=$T/lock/list
    C generate_from_keys "{\"filename\": \"ccs\", \"address\": \"$CCS_ADDRESS\", \"viewkey\": \"$vk\", \"password\": \"$WALLET_PW\", \"restore_height\": 0}" > /dev/null
    C set_subaddress_lookahead "{\"password\": \"$WALLET_PW\", \"major_idx\": 1, \"minor_idx\": 1}" > /dev/null
    C auto_refresh '{"enable": false}' > /dev/null
    CCS_CACHE=$T/lock/ccs/ccs
    mine 200
    PROPOSALS=$T/proposals4
    git init -q "$PROPOSALS"
    proposal p-alpha.md "Alpha" "100 XMR"
    proposal p-beta.md "Beta" "50.5 XMR"
    IDX=() TARGET=()
    TARGET[p-alpha.md]=100000000000000 TARGET[p-beta.md]=50500000000000
    CONF=$T/ccs4.conf STATE=$T/state4 OUT=$T/out4 SITE=$T/site4
    write_conf "$CONF" "$STATE" "$OUT" 10
    update
    read_addresses
    all_show "4. setup (monerod $OLD_V)"
    h=$(daemon_height)
    if ! send unlock=$((h + 20)) "${IDX[p-alpha.md]}:1000000000000" > /dev/null; then
        fail "4. the $OLD_V wallet would not send with an unlock_time"
    else
        send "${IDX[p-alpha.md]}:200000000000" > /dev/null
        # locked for good (unlock_time 2^64 - 1) and till 2286 (a time)
        send unlock=18446744073709551615 "${IDX[p-beta.md]}:300000000000" > /dev/null || note "4. unlock_time 2^64-1 refused by the wallet"
        send unlock=9999999999 "${IDX[p-beta.md]}:400000000000" > /dev/null
        mine 10; update
        all_show "4. a height-locked donation (unlock at $((h + 20))), wallet at $(daemon_height): not counted"
        while (($(daemon_height) < h + 20)); do mine 1; done
        update; all_show "4. at its unlock height $(daemon_height): counted"
        mine 40; update; all_show "4. 40 blocks on (in deposits.csv): counted once"
        if grep -q ",$((h + 20))\$" "$STATE/deposits.csv"; then ok "4. deposits.csv keeps its unlock_time"; else fail "4. deposits.csv lacks the unlock_time"; fi
        rm "$STATE/deposits.csv"; update; all_show "4. deposits.csv made again: counted once"
        # time-locked dust to the next subaddress, not handed out yet (alpha 1, beta 2: so 3),
        # still locked when it is handed out
        nexti=$(labels) h=$(daemon_height)
        send unlock=$((h + 20)) "$nexti:5000" > /dev/null
        mine 10; update
        proposal p-delta.md "Delta" "10 XMR"
        TARGET[p-delta.md]=10000000000000
        update; read_addresses
        check "4. delta gets the subaddress with the time-locked dust" "$nexti" "${IDX[p-delta.md]}"
        note "4. assigned.tsv: $(tr '\t\n' ' ;' 2> /dev/null < "$STATE/assigned.tsv" || echo none)"
        shows "4. delta at its hand-out (the dust still locked)" p-delta.md
        mine 30; update
        shows "4. delta after the dust's unlock height (dust sent before its hand-out)" p-delta.md
    fi
fi

echo
grep -c '^ok' "$RESULTS" | xargs printf '%s ok, '
grep -c '^FAIL' "$RESULTS" | xargs printf '%s FAIL\n' || true
cp "$RESULTS" "${REGTEST_RESULTS:-$T/results}" 2> /dev/null || true
! grep -q '^FAIL' "$RESULTS"

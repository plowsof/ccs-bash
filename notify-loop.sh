#!/usr/bin/env bash
# notify-loop.sh COMMAND...: run COMMAND every EVERY seconds, or sooner once tx-notify has
# touched FLAG, or GAP after a run that left a donation pending (its confirmation is shown a run
# after it), but at most once per GAP however many txes come: the same pacing as the compose's
# pull stage (contrib/docker/backend/step). The flag is never read, only checked for; the
# proposals' JSON (PROPOSALS_JSON) read as ccs (its owner), with a time limit. See
# docs/setup.md step 5.
set -uo pipefail   # no -e: a failed run must not end the loop
FLAG=${FLAG:-/var/lib/ccs-notify/new-tx}
GAP=${GAP:-30}
EVERY=${EVERY:-120}
PROPOSALS_JSON=${PROPOSALS_JSON:-/var/lib/ccs/out/proposals.json}
as_ccs=(runuser -u ccs --)
[[ ${CCS_AS:-} != none ]] || as_ccs=()   # (the tests: no ccs user)
pending() { "${as_ccs[@]}" timeout 10 jq -e '[.. | objects | ."amount-pending"? // 0] | any(. > 0)' "$PROPOSALS_JSON" > /dev/null 2>&1; }

last=$((-EVERY)) pend=0   # run once right away
while :; do
    since=$((SECONDS - last))
    if ((since >= EVERY)) || { ((since >= GAP)) && { [[ -e $FLAG || -L $FLAG ]] || ((pend)); }; }; then
        rm -f -- "$FLAG"   # before the run, so a tx that arrives during it gets one more run
        last=$SECONDS
        "$@"
        if pending; then pend=1; else pend=0; fi
    fi
    sleep 1
done

#!/usr/bin/env bash
# notify-loop.sh COMMAND...: run COMMAND every EVERY seconds, or sooner once tx-notify has
# touched FLAG, but at most once per GAP however many txes come. The flag is never read,
# only checked for. See docs/setup.md step 7.
set -uo pipefail   # no -e: a failed run must not end the loop
FLAG=${FLAG:-/var/lib/ccs-notify/new-tx}
GAP=${GAP:-30}
EVERY=${EVERY:-120}

last=$((-EVERY))   # run once right away
while :; do
    since=$((SECONDS - last))
    if ((since >= EVERY)) || { [[ -e $FLAG || -L $FLAG ]] && ((since >= GAP)); }; then
        rm -f -- "$FLAG"   # before the run, so a tx that arrives during it gets one more run
        last=$SECONDS
        "$@"
    fi
    sleep 1
done

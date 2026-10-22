#!/usr/bin/env bash
# notify-loop.sh COMMAND...: runs COMMAND every EVERY seconds, and sooner once the wallet's
# --tx-notify has touched FLAG, but never twice within GAP seconds. However many
# notifications come in (a wallet catching up after weeks offline, a flood of tiny
# donations), that is at most one run per GAP: the hook only touches a file, and this loop
# only checks that the file is there, it never reads it. See README, "Instant updates".
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

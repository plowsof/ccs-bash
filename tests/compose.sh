#!/usr/bin/env bash
# The backend compose's stages (contrib/docker/backend/step) without Docker: the six run as
# processes here, ccs-back.sh, ccs-front-bash, ccs-watch, git, ssh and rsync stand-ins, and take
# turns as the compose's containers do: each run's result on the push's "watch" pipe, the
# "== run" lines in the pull's output, the backup's sums (a file sent once until it changes), a
# failed ccs-bash in the run's result, a line on the pull's "now" starting a run at once; the
# watch stage after each push and between them; the healthcheck.
set -uo pipefail
here=$(dirname "$(readlink -f "$0")")
step=$here/../contrib/docker/backend/step
t=$(mktemp -d)
pids=()
# shellcheck disable=SC2317  # (the trap calls it)
cleanup() { for p in "${pids[@]}"; do kill "$p" 2> /dev/null; done; wait 2> /dev/null; rm -rf "$t"; }
trap cleanup EXIT
status=0
ok() { echo "ok   $1"; }
fail() { echo "FAIL $1"; status=1; }
stop() { for p in "${pids[@]}"; do kill "$p" 2> /dev/null; done; wait 2> /dev/null; pids=(); }
start() { for s in pull ccs-bash backup front push; do "$step" "$s" >> "$t/out-$s" 2>&1 & pids+=($!); done; }

mkdir -p "$t/bin" "$t/state/retired" "$t/www/site" "$t/pushed" "$t/proposals"
: > "$t/pull-ok" && : > "$t/watched"
echo "a.md,1" > "$t/state/proposals.csv"
# stand-ins: ccs-back.sh fails when $t/fail-bash exists; ccs-front-bash writes the site; ssh
# keeps what the backup sent; rsync to "host:" is the push, any other the local copy; ccs-watch
# keeps how it was asked
cat > "$t/bin/ccs-back" <<'EOF'
#!/usr/bin/env bash
[[ ! -e $T/fail-bash ]] || { echo "error: the stand-in fails"; exit 1; }
echo "ccs-bash ran"
EOF
cat > "$t/bin/ccs-front" <<'EOF'
#!/usr/bin/env bash
echo "<p>$(date +%s%N)</p>" > "$T/www/site/index.html" && echo "filled $T/www/site"
EOF
cat > "$t/bin/git" <<'EOF'
#!/usr/bin/env bash
echo pulled >> "$T/pulls"
EOF
cat > "$t/bin/ssh" <<'EOF'
#!/usr/bin/env bash
cat >> "$T/sent"
EOF
cat > "$t/bin/rsync" <<'EOF'
#!/usr/bin/env bash
dst=${*: -1}
if [[ $dst == *: ]]; then echo push >> "$T/pushes"; else cp -a "${*: -2:1}". "$dst"; fi
EOF
cat > "$t/bin/ccs-watch" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$T/watched"
EOF
chmod 755 "$t/bin"/*

export T=$t PATH="$t/bin:$PATH" CCS_RUN=$t/run CCS_EVERY=1 STATE_DIR=$t/state \
    CCS_BACK=$t/bin/ccs-back CCS_FRONT=$t/bin/ccs-front CCS_PROPOSALS=$t/proposals CCS_PULL_OK=$t/pull-ok \
    CCS_BACKUP=backup@test CCS_BACKUP_KEYS=$t CCS_PUSH=data@test CCS_SITE=$t/www/site CCS_PUSHED=$t/pushed \
    CCS_WATCH=$t/bin/ccs-watch
me="$(id -u):$(id -g)"
if ! CCS_UIDS="pull=$me ccs-bash=$me backup=$me front=$me push=$me watch=$me" "$step" init > /dev/null; then
    fail "init"; exit 1
fi
if [[ -p $t/run/pull/now && -p $t/run/push/watch && -p $t/run/front/wake && -d $t/run/watch && -f $t/run/watch.lock ]]; then
    ok "init: a folder and pipes for each stage, the push's lock"
else fail "init's pipes"; fi
exec 3<> "$t/run/push/watch"
start
# until run N is pushed (90 s at most)
until_pushed() { local i; for ((i = 0; i < 90; i++)); do (($(cat "$t/run/push/done" 2> /dev/null || echo 0) >= $1)) && return 0; sleep 1; done; return 1; }
line() { local l; IFS= read -r -t 30 l <&3 && printf '%s\n' "$l"; }

if until_pushed 2 && [[ $(line) == "1 pushed ok" && $(line) == "2 pushed ok" ]] \
    && [[ $(grep -c '^== run ' "$t/out-pull") -ge 2 && $(wc -l < "$t/pushes") -ge 2 && $(wc -l < "$t/pulls") -ge 2 ]] \
    && [[ -s $t/pushed/index.html && $(cat "$t/run/front/status") == *ok ]]; then
    ok "runs taken in turn: pull, ccs-bash, backup and front, push; each result on the watch pipe; the runs in the output"
else fail "the runs"; cat "$t"/out-*; ls -l "$t/run"/*; fi
if [[ $(grep -c 'a.md,1' "$t/sent") == 1 && -s $t/run/backup/sent-proposals.csv ]]; then
    ok "backup: a state file sent once, until it changes"
else fail "the backup's sums"; cat "$t/sent"; fi
echo "a.md,1 changed" > "$t/state/proposals.csv"; n=$(cat "$t/run/push/done")
if until_pushed $((n + 2)) && grep -q 'a.md,1 changed' "$t/sent"; then ok "backup: a changed file sent again"; else fail "a changed state file"; fi
while IFS= read -r -t 1 _ <&3; do :; done
touch "$t/fail-bash"; n=$(cat "$t/run/push/done")
if until_pushed $((n + 2)); then
    # (a run past ccs-bash when the stand-in began failing ends ok: the run after it)
    got=$(line); [[ $got == *" pushed ok" ]] && got=$(line)
    if [[ $got == *" pushed ccs-bash" ]] && grep -q 'error: the stand-in fails' "$t/out-ccs-bash"; then
        ok "a failed ccs-bash: in the run's result ($got), its error in its output"
    else fail "a failed ccs-bash: '$got'"; fi
else fail "runs after a failure"; fi
rm -f "$t/fail-bash"
# a line on "now" starts a run at once, however long CCS_EVERY is: the stages started again with an hour
stop
while IFS= read -r -t 1 _ <&3; do :; done
export CCS_EVERY=3600
start
n=$(cat "$t/run/push/done"); sleep 1
printf 'tx\n' 1<> "$t/run/pull/now"
if until_pushed $((n + 1)); then ok "a line on the pull's now pipe (a new tx): the next run at once"; else fail "the now pipe"; fi

# the healthcheck: every stage finished something within CCS_HEALTH seconds
unhealthy=''
for s in pull ccs-bash backup front push; do "$step" health "$s" > /dev/null || unhealthy+=" $s"; done
if [[ -z $unhealthy ]] && ! CCS_HEALTH=0 "$step" health pull > /dev/null && ! "$step" health watch > /dev/null; then
    ok "health: each stage that finished a run lately healthy; one that hasn't (watch, not started yet) not"
else fail "health:$unhealthy"; fi

# the watch stage, once the test no longer reads the pipe: after a push, the pages (under the
# lock) and the run's result; between pushes, the pages again (CCS_WATCH_EVERY)
# (no run going: CCS_EVERY is an hour; the lines of the runs before read and dropped first)
while IFS= read -r -t 1 _ <&3; do :; done
exec 3<&-
CCS_WATCH_EVERY=3600 CCS_WATCH_RANDOM=1 "$step" watch https://site.test >> "$t/out-watch" 2>&1 & pids+=($!)
n=$(cat "$t/run/push/done"); sleep 1
printf 'tx\n' 1<> "$t/run/pull/now"
for ((i = 0; i < 30; i++)); do (($(cat "$t/run/watch/done" 2> /dev/null || echo 0) > n)) && break; sleep 1; done
if [[ $(cat "$t/watched") == "https://site.test $t/pushed"$'\n'"--run ok" ]]; then
    ok "watch: after a push, the live pages against what was pushed, then the run's result"
else fail "watch after a push"; cat "$t/watched" "$t/out-watch"; fi
stop
: > "$t/watched"
exec 3<> "$t/run/push/watch"; while IFS= read -r -t 1 _ <&3; do :; done; exec 3<&-
CCS_WATCH_EVERY=1 CCS_WATCH_RANDOM=1 "$step" watch https://site.test >> "$t/out-watch" 2>&1 & pids+=($!)
sleep 4
if (($(grep -cx "https://site.test $t/pushed" "$t/watched") >= 2)) && ! grep -q -- --run "$t/watched" && "$step" health watch > /dev/null; then
    ok "watch: between pushes, the pages again and again (no run's result); healthy"
else fail "watch between pushes"; cat "$t/watched"; fi

# no lock file (init not run again since it was added): the push goes all the same, and says so
stop
rm -f "$t/run/watch.lock"
start
n=$(cat "$t/run/push/done") before=$(wc -l < "$t/pushes"); sleep 1
printf 'tx\n' 1<> "$t/run/pull/now"
if until_pushed $((n + 1)) && (($(wc -l < "$t/pushes") > before)) && grep -q 'warning: no lock' "$t/out-push"; then
    ok "no lock file: the push goes all the same, with a warning"
else fail "the push without its lock"; cat "$t/out-push"; fi
exit "$status"

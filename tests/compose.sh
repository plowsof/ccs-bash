#!/usr/bin/env bash
# The backend compose's stages (contrib/docker/backend/step) without Docker: the five run as
# processes here, ccs-back.sh, ccs-front-bash, git, ssh and rsync stand-ins, and take turns as
# the compose's containers do: each run's result on the push's "watch" pipe, the log's "== run"
# lines, the backup's sums (a file sent once until it changes), a failed ccs-bash in the run's
# result, a line on the pull's "now" starting a run at once.
set -uo pipefail
here=$(dirname "$(readlink -f "$0")")
step=$here/../contrib/docker/backend/step
t=$(mktemp -d)
pids=()
cleanup() { for p in "${pids[@]}"; do kill "$p" 2> /dev/null; done; wait 2> /dev/null; rm -rf "$t"; }
trap cleanup EXIT
status=0
ok() { echo "ok   $1"; }
fail() { echo "FAIL $1"; status=1; }

mkdir -p "$t/bin" "$t/state/retired" "$t/www/site" "$t/pushed" "$t/proposals"
: > "$t/log" && : > "$t/lock" && : > "$t/pull-ok"
echo "a.md,1" > "$t/state/proposals.csv"
# stand-ins: ccs-back.sh fails when $t/fail-bash exists; ccs-front-bash writes the site; ssh
# keeps what the backup sent; rsync to "host:" is the push, any other the local copy
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
chmod 755 "$t/bin"/*

export T=$t PATH="$t/bin:$PATH" CCS_RUN=$t/run CCS_LOG=$t/log CCS_EVERY=1 STATE_DIR=$t/state \
    CCS_BACK=$t/bin/ccs-back CCS_FRONT=$t/bin/ccs-front CCS_PROPOSALS=$t/proposals CCS_PULL_OK=$t/pull-ok \
    CCS_BACKUP=backup@test CCS_BACKUP_KEYS=$t CCS_PUSH=data@test CCS_SITE=$t/www/site CCS_PUSHED=$t/pushed \
    CCS_WATCH_LOCK=$t/lock
me="$(id -u):$(id -g)"
if ! CCS_UIDS="pull=$me ccs-bash=$me backup=$me front=$me push=$me" "$step" init > /dev/null; then
    fail "init"; exit 1
fi
if [[ -p $t/run/pull/now && -p $t/run/push/watch && -p $t/run/front/wake ]]; then ok "init: a folder and pipes for each stage"; else fail "init's pipes"; fi
exec 3<> "$t/run/push/watch"
for s in pull ccs-bash backup front push; do "$step" "$s" > /dev/null 2>&1 & pids+=($!); done
# until run N is pushed (90 s at most)
until_pushed() { local i; for ((i = 0; i < 90; i++)); do (($(cat "$t/run/push/done" 2> /dev/null || echo 0) >= $1)) && return 0; sleep 1; done; return 1; }
line() { local l; IFS= read -r -t 30 l <&3 && printf '%s\n' "$l"; }

if until_pushed 2 && [[ $(line) == "1 pushed ok" && $(line) == "2 pushed ok" ]] \
    && [[ $(grep -c '^== run ' "$t/log") -ge 2 && $(wc -l < "$t/pushes") -ge 2 && $(wc -l < "$t/pulls") -ge 2 ]] \
    && [[ -s $t/pushed/index.html && $(cat "$t/run/front/status") == *ok ]]; then
    ok "runs taken in turn: pull, ccs-bash, backup and front, push; each result on the watch pipe; the log's runs"
else fail "the runs"; cat "$t/log"; ls -l "$t/run"/*; fi
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
    if [[ $got == *" pushed ccs-bash" ]] && grep -q 'error: the stand-in fails' "$t/log"; then
        ok "a failed ccs-bash: in the run's result ($got), its error in the log"
    else fail "a failed ccs-bash: '$got'"; fi
else fail "runs after a failure"; fi
rm -f "$t/fail-bash"
# a line on "now" starts a run at once, however long CCS_EVERY is: the stages started again with an hour
for p in "${pids[@]}"; do kill "$p" 2> /dev/null; done; wait 2> /dev/null; pids=()
while IFS= read -r -t 1 _ <&3; do :; done
export CCS_EVERY=3600
for s in pull ccs-bash backup front push; do "$step" "$s" > /dev/null 2>&1 & pids+=($!); done
n=$(cat "$t/run/push/done"); sleep 1
printf 'tx\n' 1<> "$t/run/pull/now"
if until_pushed $((n + 1)); then ok "a line on the pull's now pipe (a new tx): the next run at once"; else fail "the now pipe"; fi
exit "$status"

#!/usr/bin/env bash
# Runs inside the image (CI's image job, no network). Tests the tools the backend compose's stages
# run, as the image has them (from git only git and its https transport, from openssh only ssh):
# a pull, git's https transport, ssh, the push (contrib/ccs-push), openssl's Keccak (ccs-bash),
# and ccs-watch's applets.
set -uo pipefail
status=0
ok() { echo "ok   $1"; }
fail() { echo "FAIL $1"; status=1; }
t=$(mktemp -d)
export HOME=$t GIT_CONFIG_GLOBAL=$t/gitconfig
git config --global user.name t && git config --global user.email t@t && git config --global init.defaultBranch master
if git init -q "$t/a" && git -C "$t/a" commit -q --allow-empty -m one && git -C "$t/a" bundle create -q "$t/1" HEAD master \
    && git clone -q "$t/1" "$t/b" && git -C "$t/a" commit -q --allow-empty -m two && git -C "$t/a" bundle create -q "$t/2" master \
    && git -C "$t/b" pull -q --ff-only "$t/2" master && [[ $(git -C "$t/b" log --format=%s -1) == two ]]; then
    ok "git: a clone and a pull --ff-only (its commands run by git itself)"
else fail "git: a clone and a pull"; fi
out=$(git ls-remote https://127.0.0.1:9/x 2>&1)
if [[ $out == *"unable to access"* ]]; then ok "git: its https transport (no network here: unable to access)"; else fail "git's https transport: $out"; fi
# ssh -V as a user not in /etc/passwd prints "No user exists" but runs anyway. compose.yml mounts
# the host's passwd for the push and the backup.
out=$(ssh -V 2>&1)
if [[ $out == *OpenSSH* || $out == *"No user exists for uid"* ]]; then ok "ssh"; else fail "ssh: $out"; fi
# ccs-push with busybox's tools: a first push (site-data.json as it is), then one with nothing
# changed (nothing sent: the heartbeat). ssh is a stand-in that keeps what it is sent.
here=$(dirname "$(readlink -f "$0")")
# (a function, exported: /tmp here is noexec)
echo '{"state": {}, "funds": {}, "ideas": []}' > "$t/site-data.json"
# The gate's answer: "took <sha256>" of what it was sent, if anything; none with $T/mute
# shellcheck disable=SC2317,SC2329  # (exported: ccs-push calls it)
ssh() { cat > "$T/got"; [[ -f $T/mute || ! -s $T/got ]] || echo "took $(sha256sum < "$T/got" | cut -d' ' -f1)"; }
export -f ssh
export T=$t
r1=0; bash "$here/../contrib/ccs-push" "$t/site-data.json" "$t/state" host > "$t/p1" 2>&1 || r1=$?
cp "$t/got" "$t/got1"
r2=0; bash "$here/../contrib/ccs-push" "$t/site-data.json" "$t/state" host > "$t/p2" 2>&1 || r2=$?
empty=$(test -s "$t/got" && echo no || echo yes)
# ... and with a file another user owns (this checkout's, mounted read-only), since the push stage
# runs as its own user, not ccs-bash's. CI runs this test as root and as user 10005, so a success
# that only works as root can't hide.
mkdir -p "$t/3"
r3=0; T=$t/3 bash "$here/../contrib/ccs-push" "$here/../contrib/docker/backend/compose.yml" "$t/state3" host > "$t/p3" 2>&1 || r3=$?
# A gate that answers 0 without saying it took the file: the push fails and nothing is recorded
echo '{"state": {}, "funds": {}, "ideas": [1]}' > "$t/site-data2.json" && touch "$t/mute"
r4=0; bash "$here/../contrib/ccs-push" "$t/site-data2.json" "$t/state" host > "$t/p4" 2>&1 || r4=$?
rm -f "$t/mute"
unset -f ssh
if ((r4 == 1)) && [[ $(cat "$t/state/accepted") == "$(sha256sum < "$t/site-data.json" | cut -d' ' -f1)" ]] && grep -q "didn't say it took" "$t/p4"; then
    ok "ccs-push: a gate answering 0 without saying it took the data: the push failed, the record as it was"
else cat "$t/p4"; fail "ccs-push trusted exit 0 (exit $r4)"; fi
if ((r3 == 0)) && cmp -s "$here/../contrib/docker/backend/compose.yml" "$t/3/got"; then
    ok "ccs-push: a file another user owns ($(id -u) pushing $(stat -c %u "$here/../contrib/docker/backend/compose.yml")'s)"
else cat "$t/p3"; fail "ccs-push of another user's file (exit $r3)"; fi
if ((r1 == 0 && r2 == 0)) && cmp -s "$t/site-data.json" "$t/got1" && [[ $empty == yes ]] && grep -q 'sending site-data.json' "$t/p1"; then
    ok "ccs-push: the first push site-data.json, the next (unchanged) nothing"
else cat "$t/p1" "$t/p2"; fail "ccs-push with busybox (exits $r1 $r2)"; fi
if [[ $(printf '' | openssl dgst -keccak-256 -r) == c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470* ]]; then ok "openssl's Keccak-256"; else fail "openssl's Keccak-256"; fi
# retire-wallet, run by hand in the compose (docs/handover.md, "Retiring a wallet"): it is the
# checkout's and it starts. (tests/run.sh tests what it does, in this image too.)
r=$(/opt/ccs-bash/contrib/retire-wallet 2>&1) && r="exit 0: $r"
if cmp -s /opt/ccs-bash/contrib/retire-wallet "$here/../contrib/retire-wallet" && [[ $r == *"NAME (a-z, 0-9, -)"* ]]; then
    ok "retire-wallet: the checkout's, in the image"
else fail "retire-wallet in the image: $r"; fi
missing=''
for c in basename cmp comm find head paste shuf sort stat curl jq flock timeout; do command -v "$c" > /dev/null || missing+=" $c"; done
if [[ -z $missing ]]; then ok "ccs-watch's and the stages' commands"; else fail "missing:$missing"; fi
for c in sshd ssh-agent ssh-keygen scp git-daemon git-shell scalar rsync; do command -v "$c" > /dev/null && fail "$c is in the image"; done
rm -rf "$t"
exit "$status"

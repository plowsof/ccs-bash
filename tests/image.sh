#!/usr/bin/env bash
# In the image (the CI's image job, no network): the tools the backend compose's stages run, as
# the image has them (only git and its https transport of git's, only ssh of openssh): a pull,
# git's https transport there, ssh, busybox's tar (the push: contrib/ccs-push), openssl's Keccak
# (ccs-bash), ccs-watch's applets.
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
# (ssh -V as a user /etc/passwd hasn't: "No user exists", it runs all the same; compose.yml
# mounts the host's for the push and the backup)
out=$(ssh -V 2>&1)
mkdir -p "$t/site/p" && echo x > "$t/site/p/a b.html" && printf './p/a b.html\n' > "$t/list"
if [[ $out == *OpenSSH* || $out == *"No user exists for uid"* ]] && (cd "$t/site" && tar -c -f - -T "$t/list") | tar -t -f - | grep -qx './p/a b.html'; then
    ok "ssh, and busybox's tar (a tar of the files listed)"
else fail "ssh or tar: $out"; fi
# ccs-push with busybox's tools: a first push (every file), then one with nothing changed (an
# empty tar, two zero blocks); ssh a stand-in that reads the tar and answers as the gate does
here=$(dirname "$(readlink -f "$0")")
# (a function, exported: /tmp here is noexec)
mkdir -p "$t/pushed" "$t/state"
# shellcheck disable=SC2317,SC2329  # (exported: ccs-push calls it)
ssh() { tar -t -f - > "$T/got"; }
export -f ssh
export T=$t
r1=0; bash "$here/../contrib/ccs-push" "$t/site" "$t/pushed" "$t/state" host > "$t/p1" 2>&1 || r1=$?
n1=$(wc -l < "$t/got")
r2=0; bash "$here/../contrib/ccs-push" "$t/site" "$t/pushed" "$t/state" host > "$t/p2" 2>&1 || r2=$?
unset -f ssh
if ((r1 == 0 && r2 == 0 && n1 == 1)) && [[ ! -s $t/got ]] && cmp -s "$t/site/p/a b.html" "$t/pushed/p/a b.html" && grep -q 'sending 0 of 1' "$t/p2"; then
    ok "ccs-push: the first push every file, the next an empty tar, pushed/ the site"
else cat "$t/p1" "$t/p2"; fail "ccs-push with busybox (exits $r1 $r2)"; fi
if [[ $(printf '' | openssl dgst -keccak-256 -r) == c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470* ]]; then ok "openssl's Keccak-256"; else fail "openssl's Keccak-256"; fi
missing=''
for c in basename cmp comm find head paste shuf sort stat curl jq flock timeout; do command -v "$c" > /dev/null || missing+=" $c"; done
if [[ -z $missing ]]; then ok "ccs-watch's and the stages' commands"; else fail "missing:$missing"; fi
for c in sshd ssh-agent ssh-keygen scp git-daemon git-shell scalar rsync; do command -v "$c" > /dev/null && fail "$c is in the image"; done
rm -rf "$t"
exit "$status"

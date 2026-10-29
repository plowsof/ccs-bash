#!/usr/bin/env bash
# In the image (the CI's image job, no network): the tools the backend compose's stages run, as
# the image has them (only git and its https transport of git's, only ssh of openssh): a pull,
# git's https transport there, ssh, rsync, openssl's Keccak (ccs-bash), ccs-watch's applets.
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
if [[ $out == *OpenSSH* || $out == *"No user exists for uid"* ]] && rsync --version > /dev/null; then ok "ssh and rsync"; else fail "ssh and rsync: $out"; fi
if [[ $(printf '' | openssl dgst -keccak-256 -r) == c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470* ]]; then ok "openssl's Keccak-256"; else fail "openssl's Keccak-256"; fi
missing=''
for c in basename cmp comm find head paste shuf sort stat curl jq flock timeout; do command -v "$c" > /dev/null || missing+=" $c"; done
if [[ -z $missing ]]; then ok "ccs-watch's and the stages' commands"; else fail "missing:$missing"; fi
for c in sshd ssh-agent ssh-keygen scp git-daemon git-shell scalar; do command -v "$c" > /dev/null && fail "$c is in the image"; done
rm -rf "$t"
exit "$status"

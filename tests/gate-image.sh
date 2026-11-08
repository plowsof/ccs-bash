#!/usr/bin/env bash
# Runs inside the gate's image (CI's gate-image job, no network). Checks:
# - ccs-check is owned by root and runs, with no QR reader (nothing on the web server decodes images);
# - sshd, Caddy and Tor (the site's front) are there, Tor without relay code, and their configs;
# - nothing the image deliberately leaves out is there: Python, libffi, zbar, libjpeg, giflib,
#   qrencode, libpng (the gate makes and reads no images); rsync and xxhash (ccs-check receives
#   the push); acl, attr and ncurses' other libraries (unused); an ssh client, sftp, git's servers.
set -uo pipefail
status=0
ok() { echo "ok   $1"; }
fail() { echo "FAIL $1"; status=1; }
t=$(mktemp -d)

# ccs-check: owned by root (ccs-data may have the build stage user's uid), and it runs
if [[ $(stat -c '%u:%g %a' /usr/local/bin/ccs-check) == '0:0 755' ]] && ccs-check --check; then
    ok "ccs-check: root's, 755, runs"
else fail "ccs-check: $(stat -c '%u:%g %a' /usr/local/bin/ccs-check 2>&1)"; fi
out=$(ccs-check qr png /dev/null 2>&1); rc=$?
if ((rc == 2)) && [[ $out == *"no such check"* ]]; then ok "no QR reader (ccs-check qr is gone)"; else fail "ccs-check still reads QR codes: exit $rc, $out"; fi
if grep -q OpenSSH <<<"$(/usr/sbin/sshd -V 2>&1)"; then ok "sshd"; else fail "sshd"; fi
v=$(caddy version 2>&1) && c=$(cd "$t" && CCS_SITE_HOST=http://localhost:18080 CCS_ONION=x.onion CCS_ACME_EMAIL=x@example.invalid HOME=$t XDG_CONFIG_HOME=$t \
    caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile 2>&1)
if [[ $v == v2.* || $v == 2.* ]] && [[ $c == *"Valid configuration"* ]]; then ok "caddy $v, its Caddyfile valid"; else fail "caddy: $v / ${c: -300}"; fi
v=$(tor --version 2>&1 | head -n 1) m=$(tor --list-modules 2>&1)
if [[ $v == "Tor version 0.4."* ]] && grep -qx 'relay: no' <<<"$m" && grep -qx 'dirauth: no' <<<"$m" \
    && sed "s#/var/lib/tor#$t/tor#g" /etc/tor/torrc > "$t/torrc" && tor --verify-config -f "$t/torrc" > /dev/null 2>&1; then
    ok "${v%.}: no relay or directory authority code, its torrc valid"
else fail "tor: $v; $m"; fi
present=''
for c in ssh scp sftp git-daemon git-shell ssh-agent python3 python rrsync rsync qrencode getfacl; do command -v "$c" > /dev/null && present+=" $c"; done
[[ -e /usr/lib/ssh/sftp-server ]] && present+=" sftp-server"
for l in /usr/lib/libzbar.so* /usr/lib/libjpeg.so* /usr/lib/libturbojpeg.so* /usr/lib/libgif.so* /usr/lib/libffi.so* /usr/lib/libpython* /usr/lib/libpng*.so* /usr/lib/libqrencode.so* \
    /usr/lib/libxxhash.so* /usr/lib/libacl.so* /usr/lib/libattr.so* \
    /usr/lib/libformw.so* /usr/lib/libmenuw.so* /usr/lib/libpanelw.so* /usr/lib/libncurses++w.so*; do
    [[ -e $l ]] && present+=" ${l##*/}"
done
if [[ -z $present ]]; then ok "no Python, libffi, zbar, libjpeg, giflib, qrencode, libpng, rsync, xxhash, acl, attr or unused ncurses; no ssh client, sftp or git server"; else fail "in the image:$present"; fi
# The userland is busybox, with only the applets in gate-busybox-applets (no GNU coreutils, gawk...)
gnu=''
for c in awk find grep sed tar flock cmp sort sha256sum ls; do [[ $(command -v "$c") -ef /usr/bin/busybox ]] || gnu+=" $c"; done
for c in gawk gsed gtar od dd env; do command -v "$c" > /dev/null && gnu+=" $c"; done
if [[ -z $gnu ]]; then ok "its tools busybox's, only the applets it needs"; else fail "not busybox's, or not needed:$gnu"; fi
# For building the site here: jq, the vendored ccs-front-bash release, the backend's own steps
if v=$(jq --version 2>&1) && [[ -x /usr/local/bin/ccs-gate-build && -f /usr/local/lib/ccs-gate/vendor/ccs-front-bash/ccs-front-bash.sh \
    && -f /usr/local/lib/ccs-gate/lib/site-data.sh ]]; then ok "$v, ccs-front-bash $(grep -v '^#' /usr/local/lib/ccs-gate/vendor/ccs-front-bash/RELEASE | cut -d' ' -f1) and ccs-gate-build, for the site built here"
else fail "the site's build: jq '$v', ccs-gate-build or the vendored ccs-front-bash missing"; fi
rm -rf "$t"
exit "$status"

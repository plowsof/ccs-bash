#!/usr/bin/env bash
# In the gate's image (the CI's gate-image job, no network): ccs-check root's and running, with
# no QR reader (nothing on the web server reads an image); sshd; Caddy and Tor (the site's front),
# Tor without relay code and the configs they run checked; and none of what the image
# leaves out (Python, libffi, zbar, libjpeg, giflib, qrencode, libpng: the gate makes and reads
# no image; rsync and xxhash: the push is a tar, read by ccs-check; jq, acl, attr, ncurses' other
# libraries: nothing used them; an ssh client, sftp, git's servers).
set -uo pipefail
status=0
ok() { echo "ok   $1"; }
fail() { echo "FAIL $1"; status=1; }
t=$(mktemp -d)

# ccs-check: root's (its build stage's user's uid ccs-data may have), runs
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
for c in ssh scp sftp git-daemon git-shell ssh-agent python3 python rrsync rsync qrencode jq getfacl; do command -v "$c" > /dev/null && present+=" $c"; done
[[ -e /usr/lib/ssh/sftp-server ]] && present+=" sftp-server"
for l in /usr/lib/libzbar.so* /usr/lib/libjpeg.so* /usr/lib/libturbojpeg.so* /usr/lib/libgif.so* /usr/lib/libffi.so* /usr/lib/libpython* /usr/lib/libpng*.so* /usr/lib/libqrencode.so* \
    /usr/lib/libxxhash.so* /usr/lib/libjq.so* /usr/lib/libonig.so* /usr/lib/libacl.so* /usr/lib/libattr.so* \
    /usr/lib/libformw.so* /usr/lib/libmenuw.so* /usr/lib/libpanelw.so* /usr/lib/libncurses++w.so*; do
    [[ -e $l ]] && present+=" ${l##*/}"
done
if [[ -z $present ]]; then ok "no Python, libffi, zbar, libjpeg, giflib, qrencode, libpng, rsync, xxhash, jq, acl, attr or unused ncurses; no ssh client, sftp or git server"; else fail "in the image:$present"; fi
# its userland busybox's, only the applets in gate-busybox-applets (no GNU coreutils, gawk...)
gnu=''
for c in awk find grep sed tar flock cmp sort sha256sum ls; do [[ $(command -v "$c") -ef /usr/bin/busybox ]] || gnu+=" $c"; done
for c in gawk gsed gtar od dd env; do command -v "$c" > /dev/null && gnu+=" $c"; done
if [[ -z $gnu ]]; then ok "its tools busybox's, only the applets it needs"; else fail "not busybox's, or not needed:$gnu"; fi
rm -rf "$t"
exit "$status"

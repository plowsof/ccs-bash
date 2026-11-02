#!/usr/bin/env bash
# In the gate's image (the CI's gate-image job, no network): ccs-check root's and running, with
# no QR reader (nothing on the web server reads an image); sshd; and none of what the image
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
present=''
for c in ssh scp sftp git-daemon git-shell ssh-agent python3 python rrsync rsync qrencode jq getfacl; do command -v "$c" > /dev/null && present+=" $c"; done
[[ -e /usr/lib/ssh/sftp-server ]] && present+=" sftp-server"
for l in /usr/lib/libzbar.so* /usr/lib/libjpeg.so* /usr/lib/libturbojpeg.so* /usr/lib/libgif.so* /usr/lib/libffi.so* /usr/lib/libpython* /usr/lib/libpng*.so* /usr/lib/libqrencode.so* \
    /usr/lib/libxxhash.so* /usr/lib/libjq.so* /usr/lib/libonig.so* /usr/lib/libacl.so* /usr/lib/libattr.so* \
    /usr/lib/libformw.so* /usr/lib/libmenuw.so* /usr/lib/libpanelw.so* /usr/lib/libncurses++w.so*; do
    [[ -e $l ]] && present+=" ${l##*/}"
done
if [[ -z $present ]]; then ok "no Python, libffi, zbar, libjpeg, giflib, qrencode, libpng, rsync, xxhash, jq, acl, attr or unused ncurses; no ssh client, sftp or git server"; else fail "in the image:$present"; fi
rm -rf "$t"
exit "$status"

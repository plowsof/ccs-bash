#!/usr/bin/env bash
# In the gate's image (the CI's gate-image job, no network): its QR reader as it ships (ccs-check
# qr): a code read in a PNG, a JPEG and a GIF; an inverted one only when asked; an SVG named
# .png, a JPEG named .png read as nothing; a PNG claiming 30000 by 30000 pixels not checked (2),
# never "none"; QR codes only; ccs-check root's and running; qrencode with PNG output; rsync and
# sshd; and none of what the image leaves out (Python, libffi, zbar, libjpeg, giflib; an ssh
# client, sftp, git's servers).
set -uo pipefail
here=$(dirname "$(readlink -f "$0")")
fx=$here/fixtures/qr
status=0
ok() { echo "ok   $1"; }
fail() { echo "FAIL $1"; status=1; }
t=$(mktemp -d)
q() { ccs-check qr "$@" 2> /dev/null; }
a="monero:4$(printf '%094d' 1 | tr 0 1)"

# ccs-check: root's (its build stage's user's uid ccs-data may have), runs
if [[ $(stat -c '%u:%g %a' /usr/local/bin/ccs-check) == '0:0 755' ]] && ccs-check --check; then
    ok "ccs-check: root's, 755, runs"
else fail "ccs-check: $(stat -c '%u:%g %a' /usr/local/bin/ccs-check 2>&1)"; fi
qrencode -s 4 -o "$t/qr.png" "$a"
if [[ $(q png "$t/qr.png") == "$a" && $(q jpeg "$fx/qr.jpg") == "$a" && $(q gif "$fx/qr.gif") == "$a" ]]; then
    ok "a QR code read in a PNG (qrencode's, here), a JPEG and a GIF"
else fail "reading: png '$(q png "$t/qr.png")' jpeg '$(q jpeg "$fx/qr.jpg")' gif '$(q gif "$fx/qr.gif")'"; fi
qrencode -s 4 --foreground=FFFFFF --background=000000 -o "$t/inv.png" "$a"
if ! q png "$t/inv.png" > /dev/null && [[ $(q png "$t/inv.png" inverted) == "$a" && $(q gif "$fx/inverted.gif" inverted) == "$a" ]]; then
    ok "an inverted code (light on dark): read only with inverted"
else fail "inverted codes"; fi
printf '<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"/>' > "$t/s.png"
cp "$fx/qr.jpg" "$t/j.png"
q png "$t/s.png" inverted > /dev/null; s=$?
q png "$t/j.png" inverted > /dev/null; j=$?
if ((s == 1 && j == 1)); then ok "read as the format its name says, nothing else: an SVG or a JPEG named .png: none"
else fail "a file not the format its name says: exit $s, $j"; fi
# a PNG claiming 30000x30000 pixels (fixtures/qr/bomb.png: its header and a little data)
q png "$fx/bomb.png" inverted > /dev/null; b=$?
if ((b == 2)); then ok "a PNG of 30000x30000 pixels: not checked (2), never none"; else fail "a PNG of 30000x30000 pixels: exit $b"; fi
# QR codes only: an EAN-13 barcode (fixtures/qr/ean.png) reads as nothing, a QR code still does
if [[ -f $fx/ean.png ]] && ! q png "$fx/ean.png" > /dev/null && [[ $(q png "$t/qr.png") == "$a" ]]; then ok "QR codes only: an EAN-13 barcode reads as nothing, a QR code still reads"; else fail "a barcode other than QR, or none to try"; fi
if [[ $(qrencode -s 10 -o - "$a" | head -c 8 | od -An -c | tr -d ' ') == '211PNG\r\n032\n' ]]; then ok "qrencode writes PNG (StageX's doesn't: built here)"; else fail "qrencode's PNG"; fi
if grep -q 'rsync  version' <<<"$(rsync --version 2>&1)" && grep -q OpenSSH <<<"$(/usr/sbin/sshd -V 2>&1)"; then ok "rsync, sshd"; else fail "rsync or sshd"; fi
present=''
for c in ssh scp sftp git-daemon git-shell ssh-agent python3 python rrsync; do command -v "$c" > /dev/null && present+=" $c"; done
[[ -e /usr/lib/ssh/sftp-server ]] && present+=" sftp-server"
for l in /usr/lib/libzbar.so* /usr/lib/libjpeg.so* /usr/lib/libturbojpeg.so* /usr/lib/libgif.so* /usr/lib/libffi.so* /usr/lib/libpython*; do
    [[ -e $l ]] && present+=" ${l##*/}"
done
if [[ -z $present ]]; then ok "no Python, libffi, zbar, libjpeg or giflib; no ssh client, sftp or git server"; else fail "in the image:$present"; fi
rm -rf "$t"
exit "$status"

#!/usr/bin/env bash
# In the gate's image (the CI's gate-image job, no network): the gate's QR reader as it ships
# (ccs-receive's qrscan_py, its libraries loaded): a code read in a PNG, a JPEG and a GIF; an
# inverted one only when asked; an SVG named .png, a JPEG named .png and a PNG claiming 30000 by
# 30000 pixels read as nothing; qrencode with PNG output; rrsync; sshd's own; and none of what the
# image leaves out (ImageMagick, zbarimg, an ssh client, git's servers).
set -uo pipefail
here=$(dirname "$(readlink -f "$0")")
fx=$here/fixtures/qr
status=0
ok() { echo "ok   $1"; }
fail() { echo "FAIL $1"; status=1; }
t=$(mktemp -d)
awk "/^qrscan_py='/{f=1; next} f && /^'\$/{f=0} f" /usr/local/bin/ccs-receive > "$t/q.py"
q() { python3 -I "$t/q.py" "$@" 2> /dev/null; }
a="monero:4$(printf '%094d' 1 | tr 0 1)"

if python3 -I "$t/q.py" --check; then ok "the QR reader's libraries load (libzbar, libpng, libturbojpeg, giflib)"; else fail "the QR reader's libraries"; fi
qrencode -s 4 -o "$t/qr.png" "$a"
if [[ $(q png "$t/qr.png") == "$a" && $(q jpeg "$fx/qr.jpg") == "$a" && $(q gif "$fx/qr.gif") == "$a" ]]; then
    ok "a QR code read in a PNG (qrencode's, here), a JPEG and a GIF"
else fail "reading: png '$(q png "$t/qr.png")' jpeg '$(q jpeg "$fx/qr.jpg")' gif '$(q gif "$fx/qr.gif")'"; fi
qrencode -s 4 --foreground=FFFFFF --background=000000 -o "$t/inv.png" "$a"
if ! q png "$t/inv.png" > /dev/null && [[ $(q png "$t/inv.png" inverted) == "$a" && $(q gif "$fx/inverted.gif" inverted) == "$a" ]]; then
    ok "an inverted code (light on dark): read only with inverted, as zbarimg's -Stest-inverted"
else fail "inverted codes"; fi
printf '<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"/>' > "$t/s.png"
cp "$fx/qr.jpg" "$t/j.png"
python3 -I -c '
import struct, sys, zlib
def ch(t, c): return struct.pack(">I", len(c)) + t + c + struct.pack(">I", zlib.crc32(t + c))
raw = zlib.compress(b"\0" * 30001 * 10)
open(sys.argv[1], "wb").write(b"\x89PNG\r\n\x1a\n" + ch(b"IHDR", struct.pack(">IIBBBBB", 30000, 30000, 8, 0, 0, 0, 0)) + ch(b"IDAT", raw) + ch(b"IEND", b""))' "$t/bomb.png"
if ! q png "$t/s.png" inverted > /dev/null && ! q png "$t/j.png" inverted > /dev/null && ! q png "$t/bomb.png" inverted > /dev/null; then
    ok "read as the format its name says, nothing else: an SVG or a JPEG named .png, a PNG of 30000x30000 pixels: nothing"
else fail "a file not the format its name says, or too large, was read"; fi
if [[ $(qrencode -s 10 -o - "$a" | head -c 8 | od -An -c | tr -d ' ') == '211PNG\r\n032\n' ]]; then ok "qrencode writes PNG (StageX's doesn't: built here)"; else fail "qrencode's PNG"; fi
if rrsync -help 2>&1 | grep -q 'rrsync' && /usr/sbin/sshd -V 2>&1 | grep -q OpenSSH; then ok "rrsync, sshd"; else fail "rrsync or sshd"; fi
present=''
for c in convert magick identify zbarimg ssh scp sftp git-daemon git-shell ssh-agent; do command -v "$c" > /dev/null && present+=" $c"; done
[[ -e /usr/lib/ssh/sftp-server ]] && present+=" sftp-server"
if [[ -z $present ]]; then ok "no ImageMagick, zbarimg, ssh client, sftp or git server"; else fail "in the image:$present"; fi
rm -rf "$t"
exit "$status"

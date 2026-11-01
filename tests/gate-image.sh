#!/usr/bin/env bash
# In the gate's image (the CI's gate-image job, no network): the gate's QR reader as it ships
# (ccs-receive's qrscan_py, its libraries loaded): a code read in a PNG, a JPEG and a GIF; an
# inverted one only when asked; an SVG named .png, a JPEG named .png and a PNG claiming 30000 by
# 30000 pixels read as nothing; ccs-check root's and running, its QR reader as the Python's;
# qrencode with PNG output; rrsync; sshd's own; and none of what the image leaves out (an ssh
# client, sftp, git's servers).
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
# ccs-check: root's (its build stage runs as StageX's user, whose uid ccs-data may have), runs
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
python3 -I -c '
import struct, sys, zlib
def ch(t, c): return struct.pack(">I", len(c)) + t + c + struct.pack(">I", zlib.crc32(t + c))
raw = zlib.compress(b"\0" * 30001 * 10)
open(sys.argv[1], "wb").write(b"\x89PNG\r\n\x1a\n" + ch(b"IHDR", struct.pack(">IIBBBBB", 30000, 30000, 8, 0, 0, 0, 0)) + ch(b"IDAT", raw) + ch(b"IEND", b""))' "$t/bomb.png"
if ! q png "$t/s.png" inverted > /dev/null && ! q png "$t/j.png" inverted > /dev/null && ! q png "$t/bomb.png" inverted > /dev/null; then
    ok "read as the format its name says, nothing else: an SVG or a JPEG named .png, a PNG of 30000x30000 pixels: nothing"
else fail "a file not the format its name says, or too large, was read"; fi
# QR codes only: an EAN-13 barcode (a kind zbar reads unless told not to) reads as nothing
python3 -I -c '
import struct, sys, zlib
L = ["0001101", "0011001", "0010011", "0111101", "0100011", "0110001", "0101111", "0111011", "0110111", "0001011"]
G = ["".join("1" if b == "0" else "0" for b in l)[::-1] for l in L]
R = ["".join("1" if b == "0" else "0" for b in l) for l in L]
P = ["LLLLLL", "LLGLGG", "LLGGLG", "LLGGGL", "LGLLGG", "LGGLLG", "LGGGLL", "LGLGLG", "LGLGGL", "LGGLGL"]
d = [int(c) for c in "5901234123457"]
bits = "0" * 12 + "101" + "".join((L if p == "L" else G)[x] for p, x in zip(P[d[0]], d[1:7])) + "01010" + "".join(R[x] for x in d[7:]) + "101" + "0" * 12
row = bytes(0 if b == "1" else 255 for b in bits for _ in range(3))
def ch(t, c): return struct.pack(">I", len(c)) + t + c + struct.pack(">I", zlib.crc32(t + c))
raw = zlib.compress(b"".join(b"\0" + row for _ in range(80)))
open(sys.argv[1], "wb").write(b"\x89PNG\r\n\x1a\n" + ch(b"IHDR", struct.pack(">IIBBBBB", len(row), 80, 8, 0, 0, 0, 0)) + ch(b"IDAT", raw) + ch(b"IEND", b""))' "$t/ean.png"
if ! q png "$t/ean.png" > /dev/null && [[ $(q png "$t/qr.png") == "$a" ]]; then ok "QR codes only: an EAN-13 barcode reads as nothing, a QR code still reads"; else fail "a barcode other than QR was read: $(q png "$t/ean.png")"; fi
if [[ $(qrencode -s 10 -o - "$a" | head -c 8 | od -An -c | tr -d ' ') == '211PNG\r\n032\n' ]]; then ok "qrencode writes PNG (StageX's doesn't: built here)"; else fail "qrencode's PNG"; fi
# shadow mode's QR reader (ccs-check qr): the same reads as the Python's, case by case; the PNG of
# 30000x30000 pixels "not checked" (exit 2), where the Python's says "none" (1)
g() { ccs-check qr "$@" 2> /dev/null; }
differ=''
for c in "png $t/qr.png" "jpeg $fx/qr.jpg" "gif $fx/qr.gif" "png $t/inv.png" "png $t/inv.png inverted" \
    "gif $fx/inverted.gif inverted" "png $t/s.png inverted" "png $t/j.png inverted" "png $t/ean.png"; do
    # shellcheck disable=SC2086 # (each case: kind, file, and inverted or not)
    [[ $(q $c; echo "exit $?") == "$(g $c; echo "exit $?")" ]] || differ+=" [$c]"
done
g png "$t/bomb.png" inverted > /dev/null; rc=$?
if [[ -z $differ ]] && ((rc == 2)); then ok "ccs-check qr reads each as the Python's does; the 30000x30000 PNG: not checked (2), not none"
else fail "ccs-check qr: differs on$differ, the 30000x30000 PNG exit $rc"; fi
if grep -q rrsync <<<"$(rrsync -help 2>&1)" && grep -q OpenSSH <<<"$(/usr/sbin/sshd -V 2>&1)"; then ok "rrsync, sshd"; else fail "rrsync or sshd"; fi
present=''
for c in ssh scp sftp git-daemon git-shell ssh-agent; do command -v "$c" > /dev/null && present+=" $c"; done
[[ -e /usr/lib/ssh/sftp-server ]] && present+=" sftp-server"
if [[ -z $present ]]; then ok "no ssh client, sftp or git server"; else fail "in the image:$present"; fi
rm -rf "$t"
exit "$status"

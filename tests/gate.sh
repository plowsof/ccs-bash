#!/usr/bin/env bash
# The web server's gate (contrib/ccs-receive, docs/two-machines.md): a web server set up as
# documented and a backend, in containers. A good push goes live; a push with an address that is
# neither the wallet's nor allowed, or a list that isn't the pinned one, leaves the live site as it
# was and says why. Needs docker and network.
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
name=ccs-gate-test
net=172.30.98
web=$net.2 backend=$net.3

cleanup() {
    docker rm -f "$name-web" "$name-backend" > /dev/null 2>&1 || true
    docker network rm "$name" > /dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup

# Debian 12, as in the docs (the same pinned image as tests/rrsync.sh)
docker buildx build -q --load -t "$name" - > /dev/null <<IMG
FROM debian@sha256:7ff6ba31527b9e336162fa061746c366c4b2032f4d2cff2078bea43f78efe3f8
RUN apt-get update -q && apt-get install -y -q --no-install-recommends openssh-server openssh-client rsync python3 curl qrencode zbar-tools git \
    && rm -rf /var/lib/apt/lists/*
IMG
docker network create --subnet "$net.0/24" "$name" > /dev/null
for h in web:$web backend:$backend; do
    docker run -d --name "$name-${h%%:*}" --network "$name" --ip "${h#*:}" "$name" sleep infinity > /dev/null
done
on() { local h=$1; shift; docker exec "$name-$h" bash -c "$@"; }

# a wallet of three subaddresses, and the General Fund allowed
addr() { printf '%s%094d' "${2:-9}" "$1" | tr 0 1; }   # 95 base58 characters (no 0)
list=$(for i in 0 1 2; do echo "$i $(addr "$i")"; done)
fund=$(addr 7 8)

on backend 'mkdir -p ~/.ssh && ssh-keygen -q -t ed25519 -N "" -f ~/.ssh/id_ed25519'
key=$(on backend 'cat ~/.ssh/id_ed25519.pub')
docker cp "$here/../contrib/ccs-receive" "$name-web:/usr/local/bin/ccs-receive"
on web "
    chown root:root /usr/local/bin/ccs-receive && chmod 755 /usr/local/bin/ccs-receive
    useradd --system --create-home --shell /bin/sh ccs-data
    install -d -o ccs-data -m 755 /var/lib/ccs-data /var/lib/ccs-staging
    install -d -m 755 /etc/ccs-gate
    install -o ccs-data -m 644 /dev/null /var/log/ccs-gate.log
    install -d -o ccs-data -m 755 /var/lib/ccs-gate
    printf 'ALERT_URL=http://127.0.0.1:9999/simple\nSITE_URL=https://ccs.test\n' > /etc/ccs-gate/alert.conf
    printf '%s\n' '$list' > /etc/ccs-gate/subaddresses.txt
    printf 'sha256 %s\nkey %040d\n' \"\$(sha256sum < /etc/ccs-gate/subaddresses.txt | cut -d' ' -f1)\" 0 > /etc/ccs-gate/subaddresses.txt.pin
    printf '%s  # the General Fund\n' '$fund' > /etc/ccs-gate/allowed
    echo sig > /etc/ccs-gate/subaddresses.txt.asc && echo key > /etc/ccs-gate/subaddresses.txt.key.asc
    printf '%s  ./assets/style.css\n' \$(printf 'body {}\n' | sha256sum | cut -d' ' -f1) > /etc/ccs-gate/design.sha256
    # the proposals repository, with the images that may go live (the same qrencode makes them
    # byte for byte on the backend)
    git init -q -b master /srv/proposals && mkdir -p /srv/proposals/images/p && cd /srv/proposals
    qrencode -s 4 -o images/p/qr.png 'monero:$(addr 9 B)'
    qrencode -s 4 --foreground=FFFFFF --background=000000 -o images/p/inv.png 'monero:$(addr 9 B)'
    qrencode -s 4 -o images/p/ok.png 'monero:$(addr 2)'
    git add -A && git -c user.name=t -c user.email=t@t commit -q -m images && cd /
    chown -R ccs-data /srv/proposals   # git reads a local repository only as its owner
    echo PROPOSALS_GIT=file:///srv/proposals > /etc/ccs-gate/proposals.conf
    chmod 644 /etc/ccs-gate/*
    install -d -m 755 /etc/ssh/authorized_keys
    echo 'from=\"$backend\",command=\"/usr/local/bin/ccs-receive\",restrict $key' > /etc/ssh/authorized_keys/ccs-data
    chmod 644 /etc/ssh/authorized_keys/ccs-data
    printf 'Match User ccs-data\n    AuthorizedKeysFile /etc/ssh/authorized_keys/%%u\n' >> /etc/ssh/sshd_config
    mkdir -p /run/sshd && ssh-keygen -A && /usr/sbin/sshd
"
on backend "echo '$web $(on web 'cat /etc/ssh/ssh_host_ed25519_key.pub')' > ~/.ssh/known_hosts"
# a fake bot on the web server, keeping what it is sent (the gate's alerts)
docker exec -d "$name-web" python3 -c '
import http.server
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        open("/tmp/bot.txt", "ab").write(self.rfile.read(n) + b"\n")
        self.send_response(200); self.end_headers()
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", 9999), H).serve_forever()'
bot() { on web 'cat /tmp/bot.txt 2> /dev/null || true' | tr -d '\003' | sed 's/12CCS-watch/CCS-watch/; s/04\([0-9A-Za-z]\{6\}…\)/\1/g'; }

status=0
ok() { echo "ok   $1"; }
fail() { echo "FAIL $1"; status=1; }
# site N ADDRESS [QR]: the backend's site, version N, a donation box with ADDRESS and a QR code of
# QR (default ADDRESS), the General Fund in the footer, the design's stylesheet, the signed list's
# files and some text that mentions Monero. Each version gets its own file times: two made in the
# same second, the same size, rsync would skip as unchanged.
qr64() { on backend "qrencode -s ${2:-10} -o - 'monero:$1' | base64 -w0"; }
site() {
    local qr
    qr=$(qr64 "${3:-$2}")
    on backend "rm -rf /out && mkdir -p /out/proposals /out/assets && echo '<p>v$1</p>' > /out/version.html
        printf '<meta http-equiv=\"refresh\" content=\"30\"><img src=\"logo.png\" width=\"28\" height=\"28\" alt=\"\"><a class=\"qr\" href=\"monero:%s\"><img src=\"data:image/png;base64,%s\"></a><div class=\"address\">%s</div>\n<p>Monero: a guide, in 2 parts.</p><p class=\"address\">%s</p>\n' \
            '$2' '$qr' '$2' '$fund' > /out/proposals/p.html
        echo '[{\"address\": \"$2\"}]' > /out/projects.json
        printf 'body {}\n' > /out/assets/style.css
        find /out -exec touch -d @\$((1700000000 + $1 * 100)) {} +"
    put subaddresses.txt < <(on web 'cat /etc/ccs-gate/subaddresses.txt')
    put subaddresses.txt.asc <<<sig
    put subaddresses.txt.key.asc <<<key
}
# put FILE: stdin as the backend's /out/FILE
put() { docker exec -i "$name-backend" sh -c "mkdir -p \"\$(dirname '/out/$1')\" && cat > '/out/$1'"; }
push() { on backend "rsync -a --delay-updates -e 'ssh -o BatchMode=yes -o StrictHostKeyChecking=yes' /out/ ccs-data@$web: 2>&1"; }
live() { on web 'cat /var/lib/ccs-data/version.html 2> /dev/null' | sed 's/<[^>]*>//g'; }
livefile() { on web "cat '/var/lib/ccs-data/$1' 2> /dev/null || true"; }
livepage() { on web "cat /var/lib/ccs-data/proposals/${1:-p.html} 2> /dev/null || true"; }

site 1 "$(addr 1)"
if out=$(push) && [[ $(live) == v1 ]]; then ok "a push with the wallet's addresses goes live"; else echo "$out"; fail "a good push"; fi

site 2 "$(addr 9 B)"
# The reason is written after rsync is done: the backend gets it only if ssh relays it before the
# rsync client exits (a race). The push failing and the web server's log are what's certain.
rc=0; out=$(push) || rc=$?
if ((rc)) && [[ $(live) == v2 && $(livepage) == *"$(addr 1)"* && $(livepage) != *"$(addr 9 B)"* ]] \
    && on web "grep -q 'proposals/p.html: $(addr 9 B)' /var/log/ccs-gate.log"; then
    ok "an address that isn't the wallet's: the rest of the push live, that page keeps its last good copy, the push fails, which and where in the log"
    fake=$(addr 9 B)
    if [[ $(bot | grep -c .) == 1 ]] && bot | grep -qF "[CCS-watch] the web server held back a page: donation address ${fake:0:6}…${fake: -4} is not in the signed list (its last good copy stays) @ https://ccs.test/proposals/p.html"; then
        ok "the web server tells IRC itself (it sees a bad push even when the backend is the one lying)"
    else
        bot; fail "the web server's alert"
    fi
else
    echo "push exit $rc, live $(live), output: $out"; echo "gate log:"; on web 'cat /var/log/ccs-gate.log; ls -la /var/log/ccs-gate.log'
    fail "a foreign address"
fi

push > /dev/null || true
if [[ $(bot | grep -c .) == 1 ]]; then ok "the same address refused again within the hour: no second alert"; else bot; fail "a repeated alert"; fi
site 3 "$(addr 2)"
on backend "printf 'pay %s here\n' '$(addr 8 A)' > /out/proposals/sneaky.html"
if ! push > /dev/null && [[ $(live) == v3 && -z $(livepage sneaky.html) ]]; then ok "an address anywhere in a page is checked, not only the donation box (a new page with one stays out)"; else fail "a hidden address"; fi

# The ways around a plain address search, each in a new file: that file stays out, the rest of
# the push goes live, the push fails.
held() {
    local rc=0
    push > /dev/null || rc=$?
    if ((rc)) && [[ $(live) == "v$1" && -z $(livefile "$2") ]]; then ok "held back: $3"; else echo "push exit $rc, live $(live)"; on web 'tail -n 3 /var/log/ccs-gate.log'; fail "$3"; fi
}
good=$(addr 2) fake=$(addr 9 B)
integrated=$(printf '4%0105d' 7 | tr 0 1)
v=20
for attack in \
    "split|<p>${fake:0:40}<span></span>${fake:40}</p>|an address split by markup (<span></span>)" \
    "wbr|<p>${fake:0:40}<wbr>${fake:40}</p>|an address split by <wbr>" \
    "inline|<p>${fake:0:30}<em></em>${fake:30:30}<a href=\"x\"><code>${fake:60}</code></a></p>|an address split by inline tags (<em>, <a>, <code>)" \
    "zwsp|<p>${fake:0:40}"$'\xe2\x80\x8b'"${fake:40}</p>|an address split by a zero-width space" \
    "entity|<p>&#$(printf '%d' "'${fake:0:1}");${fake:1}</p>|an address with an HTML entity in it" \
    "hexentity|<a href=\"monero:&#x$(printf '%x' "'${fake:0:1}");${fake:1}\">pay</a>|a monero: link with a hex entity in its address" \
    "percent|<a href=\"monero:%$(printf '%X' "'${fake:0:1}")${fake:1}\">pay</a>|a monero: link with a %-escape in its address" \
    "integrated|<p>$integrated</p>|an integrated address (106 characters)" \
    "datahidden|<p>data:,$fake</p>|an address hidden behind data:" \
    "qr|<a href=\"monero:$good\"><img src=\"data:image/png;base64,$(qr64 "$fake")\"></a><div class=\"address\">$good</div>|the right address, the QR code of another" \
    "notqr|<img src=\"data:image/png;base64,iVBORw0KGgo=\">|a data: image that is no QR code" \
    "svg|<img src=\"data:image/svg+xml,&lt;svg/&gt;\">|a data: image that isn't a PNG" \
    "datatab|<img src=\"da&#9;ta:image/svg+xml,&lt;svg/&gt;\">|a data: URI with a tab in its scheme, which a browser takes out" \
    "datanewline|<img src=\"d&#10;ata:image/png;base64,$(qr64 "$good")\">|the wallet's QR code, but a newline in data: (not exactly data:image/png;base64,)" \
    "junklink|<a href=\"monero:${good}x\">pay</a>|a monero: link with more than an address" \
    "box|<div class=\"address\">${good:0:50}<b></b>${good:50}</div>|an address box with markup in it" \
    "lrm|<p>${fake:0:40}"$'\xe2\x80\x8e'"${fake:40}</p>|an address split by a left-to-right mark" \
    "lrmentity|<p>${fake:0:40}&#8206;${fake:40}</p>|an address split by a left-to-right mark's entity" \
    "namedentity|<p>${fake:0:40}&ZeroWidthSpace;${fake:40}</p>|an address split by a named entity" \
    "quoted|<p>${fake:0:40}<i title=\">-\"></i>${fake:40}</p>|an address split by a tag with a quoted >" \
    "comment|<p>${fake:0:40}<!-- > -->${fake:40}</p>|an address split by a comment with a > in it" \
    "hidden|<p>${fake:0:40}<span hidden>-</span>${fake:40}</p>|an address split by hidden text" \
    "dir|<p><span dir=\"rtl\">x</span></p>|a dir attribute" \
    "svgtext|<p><svg><text>x</text></svg></p>|an <svg>" \
    "block|<pre>"$'\xe2\x96\x88\xe2\x96\x80'"</pre>|block characters, which can draw a QR code" \
    "blockentity|<pre>&#x2588;&#9600;</pre>|block characters as entities" \
    "squarename|<p>&blacksquare;&squ;</p>|squares as named entities" \
    "braille|<p>"$'\xe2\xa3\xbf'"</p>|a braille character" \
    "emoji|<p>"$'\xf0\x9f\x9f\xa5'"</p>|a coloured square emoji" \
    "mosaic|<p>&#x1FB0E;</p>|a legacy computing block mosaic" \
    "digitname|<pre>&blk14;&blk34;</pre>|a block character as an entity named with digits" \
    "shy|<p>${fake:0:40}&shy${fake:40}</p>|an address split by &shy without its ;" \
    "tablink|<a href=\"mon&#9;ero:${fake:0:40}&#9;${fake:40}\">pay</a>|a monero: link split by tabs, which a browser takes out" \
    "formlink|<form action=\"monero:${fake:0:40}&#10;${fake:40}\"><button>pay</button></form>|a monero: URL in a form, split by a newline" \
    "alt|<p><img src=\"x\" title=\" alt=q\" alt=\"${fake:0:40}\">${fake:40}</p>|an address split by a broken image's alt text" \
    "charset|<meta charset=\"iso-2022-jp\"><p>x</p>|a charset that isn't UTF-8" \
    "refresh|<meta http-equiv=\"refresh\" content=\"0;url=https://example.com/\">|a refresh to another site" \
    "font|<p>${fake:0:40}<font color=\"#fff\">x</font>${fake:40}</p>|an address split by white text in a <font>" \
    "bgcolor|<table><tr><td bgcolor=\"#000\" width=\"9\"></td></tr></table>|table cells coloured with bgcolor" \
    "manyimgs|$(printf '<img src="logo.png" width="9" height="9" alt="">%.0s' $(seq 65))|65 small images, enough to draw a QR code" \
    "small|<img src=\"data:image/png;base64,$(qr64 "$good" 4)\">|the wallet's QR code, but not as qrencode -s 10 makes it" \
    "extra|<img src=\"data:image/png;base64,$(on backend "python3 -c 'import sys,struct,zlib;d=sys.stdin.buffer.read();t=b\"tEXt\";c=b\"k\\x00v\";sys.stdout.buffer.write(d[:33]+struct.pack(\">I\",len(c))+t+c+struct.pack(\">I\",zlib.crc32(t+c))+d[33:])' < <(qrencode -s 10 -o - 'monero:$good') | base64 -w0")\">|the wallet's QR code with a chunk qrencode doesn't write"; do
    IFS='|' read -r file html what <<<"$attack"
    v=$((v + 1)); site "$v" "$good"
    put "proposals/$file.html" <<<"$html"
    held "$v" "proposals/$file.html" "$what"
done
# what reads like an address only to a gate that reads too much: these go live
passes() {
    local rc=0
    push > /dev/null || rc=$?
    if ((!rc)) && [[ $(live) == "v$1" && -n $(livefile "$2") ]]; then ok "goes live: $3"; else echo "push exit $rc, live $(live)"; on web 'tail -n 3 /var/log/ccs-gate.log'; fail "$3"; fi
}
for page in \
    "pcttext|<p>%$(printf '%X' "'${fake:0:1}")${fake:1}</p>|a %-escape in a page's text, which a browser shows as it is (only a monero: link's are read)" \
    "paragraphs|<p>${fake:0:40}</p><p>${fake:40}</p>|halves in two paragraphs, two lines on the page (block tags are a space)" \
    "cells|<table><tr><td>${fake:0:40}</td><td>${fake:40}</td></tr></table><div>${fake:0:40}<br>${fake:40}</div>|halves in two table cells, or either side of a <br>"; do
    IFS='|' read -r file html what <<<"$page"
    v=$((v + 1)); site "$v" "$good"
    put "proposals/$file.html" <<<"$html"
    passes "$v" "proposals/$file.html" "$what"
done
v=$((v + 1)); site "$v" "$good"
put projects.json <<<"[{\"address\": \"$good\", \"title\": \"R&D notes\", \"url\": \"data:text/plain,x\"}]"
passes "$v" projects.json "JSON with & and data: in its text (entities and data: URIs are a page's)"
[[ $(livefile projects.json) == *'R&D'* ]] || fail "the JSON with & and data: isn't the one live"
# names an rsync exclude pattern can't hold exactly: a backslash with no wildcard, a wildcard, both
for file in 'back\slash' 'star*' 'both\[x]'; do
    v=$((v + 1)); site "$v" "$good"
    put "proposals/$file.html" <<<"<p>$fake</p>"
    held "$v" "proposals/$file.html" "a page named $file.html"
done
v=$((v + 1)); site "$v" "$good"; put assets/evil.css <<<'.address::after { content: "x" }'
held "$v" assets/evil.css "a stylesheet that isn't the design's"
v=$((v + 1)); site "$v" "$good"; put assets/style.css <<<'.address { display: none }'
rc=0; push > /dev/null || rc=$?
if ((rc)) && [[ $(live) == "v$v" && $(livefile assets/style.css) == 'body {}' ]]; then ok "held back: a design file changed (its last good copy stays)"; else fail "a changed design file"; fi
v=$((v + 1)); site "$v" "$good"; printf '0 %s\n' "$fake" | put subaddresses.txt
rc=0; push > /dev/null || rc=$?
if ((rc)) && [[ $(livefile subaddresses.txt) != *"$fake"* ]]; then ok "held back: a subaddress list that isn't the one installed here"; else fail "a swapped list"; fi
v=$((v + 1)); site "$v" "$good"; on backend "qrencode -s 4 -o /tmp/q.png 'monero:$fake'"; docker exec "$name-backend" sh -c 'mkdir -p /out/images/p && cp /tmp/q.png /out/images/p/qr.png'
held "$v" images/p/qr.png "a proposal image that is a QR code of another address"
v=$((v + 1)); site "$v" "$good"; docker exec "$name-backend" sh -c "mkdir -p /out/images/p && qrencode -s 4 --foreground=FFFFFF --background=000000 -o /out/images/p/inv.png 'monero:$fake'"
held "$v" images/p/inv.png "a proposal image that is an inverted QR code of another address"
v=$((v + 1)); site "$v" "$good"; docker exec "$name-backend" sh -c "mkdir -p /out/images/p && qrencode -s 4 -o /out/images/p/ok.png 'monero:$good'"
if push > /dev/null && [[ $(live) == "v$v" ]] && on web 'test -s /var/lib/ccs-data/images/p/ok.png'; then ok "a proposal image with the wallet's QR code goes live"; else fail "a good proposal image"; fi
# an image the proposals repository doesn't have, at that path or at all: half a QR code, say
v=$((v + 1)); site "$v" "$good"; docker exec "$name-backend" sh -c "mkdir -p /out/images/p && qrencode -s 4 -o /out/images/p/half.png 'monero:$good'"
held "$v" images/p/half.png "a proposal image the proposals repository doesn't have"
v=$((v + 1)); site "$v" "$good"; docker exec "$name-backend" sh -c "mkdir -p /out/images/q && qrencode -s 4 -o /out/images/q/ok.png 'monero:$good'"
held "$v" images/q/ok.png "a proposal image the repository has, but at another path"
on backend 'rm -rf /out/images/q'
v=$((v + 1)); site "$v" "$good"; docker exec "$name-backend" sh -c "mkdir -p /out/images/p && qrencode -s 5 -o /out/images/p/ok.png 'monero:$good'"
rc=0; push > /dev/null || rc=$?
if ((rc)) && [[ $(live) == "v$v" ]] && on web 'cmp -s /var/lib/ccs-data/images/p/ok.png /srv/proposals/images/p/ok.png'; then ok "held back: a proposal image changed from the repository's (its last good copy stays)"; else fail "a changed proposal image"; fi
on web "sed -i 's#=.*#=file:///nowhere#' /etc/ccs-gate/proposals.conf"
v=$((v + 1)); site "$v" "$good"; docker exec "$name-backend" sh -c "mkdir -p /out/images/p && qrencode -s 4 -o /out/images/p/ok.png 'monero:$good' && cp /out/images/p/ok.png /out/images/p/new.png"
held "$v" images/p/new.png "a new proposal image while the repository can't be read"
on web "sed -i 's#=.*#=file:///srv/proposals#' /etc/ccs-gate/proposals.conf"
on backend 'rm -rf /out/images'
# a NUL byte, which HTML drops from the text
v=$((v + 1)); site "$v" "$good"; on backend "printf '<p>%s\\000%s</p>\\n' '${fake:0:40}' '${fake:40}' > /out/proposals/nul.html"
held "$v" proposals/nul.html "an address split by a NUL byte"
# an image named as a page: a browser shows <img src="x.html"> by its bytes
v=$((v + 1)); site "$v" "$good"; on backend "qrencode -s 10 -o /out/proposals/img.html 'monero:$fake'"
held "$v" proposals/img.html "a PNG named .html"
v=$((v + 1)); site "$v" "$good"; on backend "qrencode -s 10 -o /out/projects.json 'monero:$fake'"
rc=0; push > /dev/null || rc=$?
if ((rc)) && [[ $(live) == "v$v" && $(livefile projects.json) == '[{'* ]]; then ok "held back: a PNG as projects.json (its last good copy stays)"; else fail "a PNG as projects.json"; fi
# a good QR code with more beside it: zbarimg reads the good one, the rest is another's
v=$((v + 1)); site "$v" "$good"
docker exec -i "$name-backend" sh -c "python3 - '$good' > /tmp/two.b64" <<'PY'
import base64, subprocess, sys, zlib, struct
def png(w, h, rows):
    raw = b"".join(b"\x00" + bytes(r) for r in rows)
    ch = lambda t, c: struct.pack(">I", len(c)) + t + c + struct.pack(">I", zlib.crc32(t + c))
    return b"\x89PNG\r\n\x1a\n" + ch(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 0, 0, 0, 0)) + ch(b"IDAT", zlib.compress(raw)) + ch(b"IEND", b"")
m = [l for l in subprocess.run(["qrencode", "-t", "ASCII", "-m", "4", "monero:" + sys.argv[1]], capture_output=True, text=True).stdout.splitlines()]
q = [[0 if l[2 * x] == "#" else 255 for x in range(len(l) // 2) for _ in range(10)] for l in m for _ in range(10)]
rows = [r + [255] * 200 + [0 if (x // 10) % 2 else 255 for x in range(200)] for r in q]
print(base64.b64encode(png(len(rows[0]), len(rows), rows)).decode())
PY
put proposals/two.html <<<"<img src=\"data:image/png;base64,$(on backend 'cat /tmp/two.b64')\">"
if on backend 'base64 -d /tmp/two.b64 > /tmp/two.png && zbarimg -q --raw /tmp/two.png' | grep -qx "monero:$good"; then held "$v" proposals/two.html "a good QR code with more drawn beside it"; else fail "the two-part test image doesn't read"; fi
# two pushes at once: the second waits for the first (one staging folder, one at a time)
v=$((v + 1)); site "$v" "$good"
on backend "(rsync -a -e 'ssh -o BatchMode=yes' /out/ ccs-data@$web: > /tmp/a 2>&1; echo \$? >> /tmp/a) & (rsync -a -e 'ssh -o BatchMode=yes' /out/ ccs-data@$web: > /tmp/b 2>&1; echo \$? >> /tmp/b) & wait"
if [[ $(on backend 'tail -n 1 /tmp/a; tail -n 1 /tmp/b') == $'0\n0' && $(live) == "v$v" ]]; then ok "two pushes at once both go through, one after the other"; else on backend 'cat /tmp/a /tmp/b'; fail "two pushes at once"; fi

site 4 "$(addr 2)"
if push > /dev/null && [[ $(live) == v4 ]]; then ok "the next good push goes live again"; else fail "recovery"; fi

on web "echo '3 $(addr 3)' >> /etc/ccs-gate/subaddresses.txt"
site 5 "$(addr 3)"
if ! out=$(push) && [[ $(live) == v4 && $out == *"is not the list"*".pin names"* ]] \
    && bot | grep -qF "[CCS-watch] the web server refuses every push: its signed list isn't the one its .pin names"; then ok "a list that isn't the pinned one: every push refused"; else echo "$out"; fail "a changed list"; fi

# rrsync's limits still hold through the gate: no deleting, nothing outside its folder
on web "echo keep > /var/lib/ccs-data/keep.txt"
site 6 "$(addr 2)"
on backend "rsync -a --delete -e 'ssh -o BatchMode=yes' /out/ ccs-data@$web: > /dev/null 2>&1" || true
on backend "echo x > /tmp/x && rsync -e 'ssh -o BatchMode=yes' /tmp/x ccs-data@$web:../../../tmp/escaped > /dev/null 2>&1" || true
if [[ $(on web 'cat /var/lib/ccs-data/keep.txt') == keep ]] && ! on web 'test -e /tmp/escaped || test -e /var/lib/escaped'; then
    ok "no deleting and nothing outside the folder, through the gate too"
else
    fail "rrsync's limits"
fi

# the key still runs nothing but the gate
if ! on backend "ssh -o BatchMode=yes ccs-data@$web 'cat /etc/passwd' 2>&1" | grep -q root; then ok "the key runs nothing else"; else fail "the key ran a command"; fi
# the heartbeat: pushes are the backend's; the web server's timer alerts when none arrive
hb() { on web 'su -s /bin/bash ccs-data -c "/usr/local/bin/ccs-receive --heartbeat"'; }
late() { bot | grep -c 'no push from the backend' || true; }
on web "printf 'sha256 %s\nkey %040d\n' \"\$(sha256sum < /etc/ccs-gate/subaddresses.txt | cut -d' ' -f1)\" 0 > /etc/ccs-gate/subaddresses.txt.pin"   # the list above, pinned again
on web 'rm -f /var/lib/ccs-data/keep.txt'   # root's, from the test above: ccs-data can't copy it
site 7 "$(addr 2)"
push > /dev/null
hb
if [[ $(late) == 0 ]]; then ok "heartbeat: a recent push, no alert"; else bot; fail "heartbeat after a push"; fi
# 1 minute, not 15: a CI machine may have been up less than 15 (then the heartbeat waits), and
# not before it has been up that long either
on web "echo HEARTBEAT_MINUTES=1 >> /etc/ccs-gate/alert.conf && touch -d '-5 min' /var/lib/ccs-gate/last-push"
on web 'until (($(cut -d. -f1 /proc/uptime) >= 70)); do sleep 5; done'
hb
if [[ $(late) == 0 ]]; then ok "heartbeat: the first late check waits for a second"; else fail "heartbeat alerted on one check"; fi
hb
if bot | grep -qE '^\[CCS-watch\] no push from the backend for [5-9] minutes: is it running\? .* @ https://ccs.test$'; then
    ok "heartbeat: no push for longer than HEARTBEAT_MINUTES, two checks in a row: the web server tells IRC"
else bot; fail "heartbeat alert"; fi
hb
if [[ $(late) == 1 ]]; then ok "heartbeat: once an hour, not every check"; else bot; fail "a repeated heartbeat alert"; fi
site 8 "$(addr 2)"
push > /dev/null
hb
if bot | grep -qF '[CCS-watch] pushes from the backend arrive again @ https://ccs.test'; then ok "heartbeat: pushes arrive again, IRC is told"; else bot; fail "heartbeat recovery"; fi
on web 'rm -f /var/lib/ccs-gate/last-push /var/lib/ccs-gate/alert-heartbeat'
hb
if [[ $(late) == 1 ]]; then ok "heartbeat: before any push, nothing is known: no alert"; else fail "heartbeat without a push"; fi

exit "$status"

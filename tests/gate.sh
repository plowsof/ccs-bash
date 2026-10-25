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
RUN apt-get update -q && apt-get install -y -q --no-install-recommends openssh-server openssh-client rsync python3 curl qrencode zbar-tools \
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
qr64() { on backend "qrencode -s 4 -o - 'monero:$1' | base64 -w0"; }
site() {
    local qr
    qr=$(qr64 "${3:-$2}")
    on backend "rm -rf /out && mkdir -p /out/proposals /out/assets && echo '<p>v$1</p>' > /out/version.html
        printf '<a class=\"qr\" href=\"monero:%s\"><img src=\"data:image/png;base64,%s\"></a><div class=\"address\">%s</div>\n<p>Monero: a guide, in 2 parts.</p><p class=\"address\">%s</p>\n' \
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
    "zwsp|<p>${fake:0:40}"$'\xe2\x80\x8b'"${fake:40}</p>|an address split by a zero-width space" \
    "entity|<p>&#$(printf '%d' "'${fake:0:1}");${fake:1}</p>|an address with an HTML entity in it" \
    "hexentity|<a href=\"monero:&#x$(printf '%x' "'${fake:0:1}");${fake:1}\">pay</a>|a monero: link with a hex entity in its address" \
    "percent|<a href=\"monero:%$(printf '%X' "'${fake:0:1}")${fake:1}\">pay</a>|a monero: link with a %-escape in its address" \
    "integrated|<p>$integrated</p>|an integrated address (106 characters)" \
    "datahidden|<p>data:,$fake</p>|an address hidden behind data:" \
    "qr|<a href=\"monero:$good\"><img src=\"data:image/png;base64,$(qr64 "$fake")\"></a><div class=\"address\">$good</div>|the right address, the QR code of another" \
    "notqr|<img src=\"data:image/png;base64,iVBORw0KGgo=\">|a data: image that is no QR code" \
    "svg|<img src=\"data:image/svg+xml,&lt;svg/&gt;\">|a data: image that isn't a PNG" \
    "junklink|<a href=\"monero:${good}x\">pay</a>|a monero: link with more than an address" \
    "box|<div class=\"address\">${good:0:50}<b></b>${good:50}</div>|an address box with markup in it" \
    "lrm|<p>${fake:0:40}"$'\xe2\x80\x8e'"${fake:40}</p>|an address split by a left-to-right mark" \
    "lrmentity|<p>${fake:0:40}&#8206;${fake:40}</p>|an address split by a left-to-right mark's entity" \
    "namedentity|<p>${fake:0:40}&ZeroWidthSpace;${fake:40}</p>|an address split by a named entity" \
    "quoted|<p>${fake:0:40}<i title=\">-\"></i>${fake:40}</p>|an address split by a tag with a quoted >" \
    "comment|<p>${fake:0:40}<!-- > -->${fake:40}</p>|an address split by a comment with a > in it" \
    "hidden|<p>${fake:0:40}<span hidden>-</span>${fake:40}</p>|an address split by hidden text" \
    "dir|<p><span dir=\"rtl\">x</span></p>|a dir attribute" \
    "svgtext|<p><svg><text>x</text></svg></p>|an <svg>"; do
    IFS='|' read -r file html what <<<"$attack"
    v=$((v + 1)); site "$v" "$good"
    put "proposals/$file.html" <<<"$html"
    held "$v" "proposals/$file.html" "$what"
done
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
on backend 'rm -rf /out/images'
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

#!/usr/bin/env bash
# The web server's gate (contrib/ccs-receive, docs/two-machines.md): a web server set up as
# documented and a backend, in containers, with a small design in the release zip's shape (its
# pages and parts) and a proposals repository. A good push goes live; a page that isn't the
# design's filled as ccs-front-bash fills it, an address that is neither the wallet's nor allowed,
# or a list that isn't the pinned one, leaves the live file as it was and says why. Needs docker
# and network. With GATE_IMAGE, the web server is the gate's image (contrib/docker/web): its own
# ccs-receive, its sshd as compose.yml starts it, its users from its init.
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
name=ccs-gate-test
net=172.30.98
web=$net.2 backend=$net.3
files=$(mktemp -d)

cleanup() {
    docker rm -f "$name-web" "$name-backend" > /dev/null 2>&1 || true
    docker network rm "$name" > /dev/null 2>&1 || true
    rm -rf "$files"
}
trap cleanup EXIT
cleanup; files=$(mktemp -d)

# Debian 12, as in the docs (the same pinned image as tests/rrsync.sh)
docker buildx build -q --load -t "$name" - > /dev/null <<IMG
FROM debian@sha256:7ff6ba31527b9e336162fa061746c366c4b2032f4d2cff2078bea43f78efe3f8
RUN apt-get update -q && apt-get install -y -q --no-install-recommends openssh-server openssh-client rsync python3 curl qrencode git \
    libzbar0 libpng16-16 libturbojpeg0 libgif7 \
    && rm -rf /var/lib/apt/lists/*
IMG
docker network create --subnet "$net.0/24" "$name" > /dev/null
img=${GATE_IMAGE:-}
if [[ $img ]]; then
    docker run -d --name "$name-web" --network "$name" --ip "$web" --tmpfs /etc/ccs-ssh:mode=755 --entrypoint sleep "$img" infinity > /dev/null
    docker exec -e CCS_DATA_UID=997:997 -e CCS_BACKUP_UID=998:998 "$name-web" /usr/local/bin/ccs-web-init > /dev/null
    # (ccs-data by its id for docker exec: the image's passwd is a link Docker doesn't follow)
    keys=/etc/ccs-ssh/authorized_keys hostkey=/etc/ccs-ssh/keys/ssh_host_ed25519_key.pub adduser=: data=997:997
    sshd='/usr/sbin/sshd -p 22 -o AllowUsers=ccs-data -o ForceCommand=/usr/local/bin/ccs-receive'
else
    docker run -d --name "$name-web" --network "$name" --ip "$web" "$name" sleep infinity > /dev/null
    keys=/etc/ssh/authorized_keys hostkey=/etc/ssh/ssh_host_ed25519_key.pub adduser='useradd --system --create-home --shell /bin/sh ccs-data' data=ccs-data
    sshd="printf 'Match User ccs-data\\n    AuthorizedKeysFile /etc/ssh/authorized_keys/%%u\\n' >> /etc/ssh/sshd_config && mkdir -p /run/sshd && ssh-keygen -A && /usr/sbin/sshd"
fi
docker run -d --name "$name-backend" --network "$name" --ip "$backend" "$name" sleep infinity > /dev/null
on() { local h=$1; shift; docker exec "$name-$h" bash -c "$@"; }

# a wallet of three subaddresses, and the General Fund allowed
addr() { printf '%s%094d' "${2:-9}" "$1" | tr 0 1; }   # 95 base58 characters (no 0)
list=$(for i in 0 1 2; do echo "$i $(addr "$i")"; done)
fund=$(addr 7 8)

# The design: pages with regions, parts with {{slots}}, as ccs-front-hugo's release zip has them
# (its README: "What ccs-front-bash fills in"); the General Fund in every page's footer.
d=$files/design
mkdir -p "$d/parts" "$d/ideas" "$d/assets"
foot="<footer><p class=\"address\">$fund</p>"$'\n'"<!-- ccs:onion -->"$'\n'"<!-- /ccs:onion -->"$'\n'"</footer>"
printf '<!doctype html>\n<html lang="en">\n<head><meta charset="utf-8"><title>CCS</title><link rel="stylesheet" href="./assets/style.css"></head>\n<body>\n<p>Funding required: <!-- ccs:count fr -->\n0\n<!-- /ccs:count fr --></p>\n<!-- ccs:filters -->\n<!-- /ccs:filters -->\n%s\n</body>\n</html>\n' "$foot" > "$d/index.html"
printf '<!doctype html>\n<html lang="en">\n<head><meta charset="utf-8"><title>Ideas</title></head>\n<body>\n<!-- ccs:list idea -->\n<!-- /ccs:list idea -->\n%s\n</body>\n</html>\n' "$foot" > "$d/ideas/index.html"
printf '<!doctype html>\n<html lang="en">\n<head><meta charset="utf-8"><title>{{name}}</title></head>\n<body>\n<h1>{{name}}</h1>\n<p class="by">{{author}} {{funding_date}} {{tag_links}}</p>\n<!-- ccs:%s -->\n<!-- /ccs:%s -->\n<div class="body">\n{{body}}\n</div>\n<!-- ccs:milestones -->\n<!-- /ccs:milestones -->\n%s\n</body>\n</html>\n' donate donate "$foot" > "$d/parts/proposal-fr.html"
for s in wip cp; do sed 's/ccs:donate/ccs:funded/' "$d/parts/proposal-fr.html" > "$d/parts/proposal-$s.html"; done
printf '<p>Raised {{raised}} of {{amount}} XMR{{pending_note}}</p>\n<a class="qr" href="monero:{{address}}"><img src="{{qr}}" alt="QR code of the address below"></a>\n<div class="address">{{address}}</div>{{verify_link}}\n' > "$d/parts/donate.html"
printf '<p>Completed {{done}} of {{milestones}} milestones, raised {{raised}} of {{amount}} XMR</p>\n' > "$d/parts/funded.html"
printf '<a class="card idea" href="{{url}}"><h3>{{name}}</h3><p>{{author}}, {{date}}{{funding_note}}</p><p class="labels">{{tags}}</p><p>{{upvotes}} {{downvotes}}</p></a>\n' > "$d/parts/card-idea.html"
for s in fr wip cp; do cp "$d/parts/card-idea.html" "$d/parts/card-$s.html"; done
printf '<div class="milestone"><h3>{{name}}</h3><p>{{funds}}</p><p>{{date}}</p></div>\n' > "$d/parts/milestone-done.html"
printf '<div class="milestone"><h3>{{name}}</h3><p>{{funds}}</p></div>\n' > "$d/parts/milestone-todo.html"
printf '<div class="payout"><p>{{amount}}</p><p>{{date}}</p></div>\n' > "$d/parts/payout.html"
printf '<p class="empty">%s</p>\n' 'Nothing here right now.' > "$d/parts/empty.html"
printf '<p class="empty">%s</p>\n' 'No milestones.' > "$d/parts/no-milestones.html"
printf '<p class="empty">%s</p>\n' 'No payouts yet.' > "$d/parts/no-payouts.html"
printf '<p>%s</p>\n' 'No list yet.' > "$d/parts/no-list.html"
printf '<span class="segment done"></span>\n' > "$d/parts/segment-done.html"
printf '<span class="segment"></span>\n' > "$d/parts/segment-todo.html"
printf '<span class="label {{color}}">{{tag}}</span>\n' > "$d/parts/label.html"
printf '<a class="label {{color}}" href="{{href}}">{{tag}}</a>\n' > "$d/parts/label-link.html"
printf '<a class="filter {{color}}{{active}}" href="{{href}}">{{tag}}<span class="count">{{count}}</span></a>\n' > "$d/parts/filter.html"
printf '<nav class="filters">{{filters}}</nav>\n' > "$d/parts/filters.html"
printf '<p>{{address}} {{viewkey}}{{network}} {{fingerprint}} {{wallet_source}}</p>\n' > "$d/parts/verify.html"
printf '\n<p class="verify"><a href="../verify/">Check this address</a></p>\n' > "$d/parts/verify-link.html"
printf '<p class="footer-onion">Also on Tor: <a href="http://{{onion}}/">{{onion}}</a></p>\n' > "$d/parts/onion.html"
printf 'body {}\n' > "$d/assets/style.css"
# markdown.awk, as ccs-front-bash's makes a proposal's text (a stand-in: one paragraph, escaped)
cat > "$files/markdown.awk" <<'AWK'
function out(    b) { b = body; gsub(/&/, "\\&amp;", b); gsub(/</, "\\&lt;", b); gsub(/>/, "\\&gt;", b)
    printf "{\"file\":\"%s\",\"body\":\"<p>%s</p>\",\"milestones\":[],\"payouts\":[]}\n", name, b }
FNR == 1 { if (started) out(); started = 1; name = FILENAME; sub(/.*\//, "", name); sub(/\.md$/, "", name); body = "" }
{ body = body (body == "" ? "" : " ") $0 }
END { if (started) out() }
AWK
# the backend's site, as ccs-front-bash fills the design: gen OUT N ADDRESS QR64 [IDEA TITLE...]
cat > "$files/gen.py" <<'PY'
import html, os, re, sys
design, out, n, addr, qr = sys.argv[1:6]
read = lambda p: open(p, encoding="utf-8").read()
def part(p):
    t = read(design + "/parts/" + p + ".html"); return t[:-1] if t.endswith("\n") else t
fill = lambda t, v: re.sub(r"\{\{([a-z_]+)\}\}", lambda m: v[m.group(1)], t)
def region(t, name, html_):
    a, b = "<!-- ccs:" + name + " -->", "<!-- /ccs:" + name + " -->"
    return t[:t.index(a)] + a + "\n" + html_ + "\n" + b + t[t.index(b) + len(b):]
def write(p, t):
    if "<!-- ccs:onion -->" in t:   # the footer: the onion line with ONION, as ccs-front-bash fills it
        t = region(t, "onion", fill(part("onion"), {"onion": os.environ["ONION"]}) if os.environ.get("ONION") else "")
    os.makedirs(os.path.dirname(out + "/" + p), exist_ok=True); open(out + "/" + p, "w", encoding="utf-8").write(t)
write("index.html", region(region(read(design + "/index.html"), "count fr", n), "filters", ""))
cards = [fill(part("card-idea"), {"url": "https://forge.test/ccs-proposals/pulls/%d" % i, "name": html.escape(t), "author": "someone",
         "date": "October 1, 2026", "funding_note": "", "tags": "", "upvotes": "1", "downvotes": "0"}) for i, t in enumerate(sys.argv[6:])]
write("ideas/index.html", region(read(design + "/ideas/index.html"), "list idea", "\n".join(cards) or part("empty")))
page = fill(read(design + "/parts/proposal-fr.html"), {"name": "A proposal", "author": "someone", "funding_date": "October 22, 2026", "tag_links": "",
             "body": "<p>Monero: a guide, in 2 parts.</p>"})
page = region(page, "donate", fill(part("donate"), {"raised": "1.5", "amount": "10", "pending_note": os.environ.get("PENDING_NOTE", ""), "address": addr,
             "qr": "data:image/png;base64," + qr, "verify_link": read(design + "/parts/verify-link.html").rstrip("\n")}))
write("proposals/p.html", region(page, "milestones", part("no-milestones")) + "\n")
PY

on backend 'mkdir -p ~/.ssh && ssh-keygen -q -t ed25519 -N "" -f ~/.ssh/id_ed25519'
key=$(on backend 'cat ~/.ssh/id_ed25519.pub')
[[ $img ]] || docker cp "$here/../contrib/ccs-receive" "$name-web:/usr/local/bin/ccs-receive"
docker cp "$d" "$name-web:/tmp/design" && docker cp "$files/markdown.awk" "$name-web:/tmp/markdown.awk"
docker cp "$d" "$name-backend:/design" && docker cp "$files/gen.py" "$name-backend:/gen.py"
on web "
    chown root:root /usr/local/bin/ccs-receive && chmod 755 /usr/local/bin/ccs-receive
    $adduser
    install -d -o ccs-data -m 755 /var/lib/ccs-data /var/lib/ccs-staging
    install -d -m 755 /etc/ccs-gate /etc/ccs-gate/design
    install -o ccs-data -m 644 /dev/null /var/log/ccs-gate.log
    install -d -o ccs-data -m 755 /var/lib/ccs-gate
    printf 'ALERT_URL=http://127.0.0.1:9999/simple\nSITE_URL=https://ccs.test\n' > /etc/ccs-gate/alert.conf
    printf '%s\n' '$list' > /etc/ccs-gate/subaddresses.txt
    printf 'sha256 %s\nkey %040d\n' \"\$(sha256sum < /etc/ccs-gate/subaddresses.txt | cut -d' ' -f1)\" 0 > /etc/ccs-gate/subaddresses.txt.pin
    printf '%s  # the General Fund\n' '$fund' > /etc/ccs-gate/allowed
    echo sig > /etc/ccs-gate/subaddresses.txt.asc && echo key > /etc/ccs-gate/subaddresses.txt.key.asc
    # the design's release, unpacked; its files but the pages in design.sha256; markdown.awk
    cp -r /tmp/design /etc/ccs-gate/design/v0.0.1 && cp /tmp/markdown.awk /etc/ccs-gate/markdown.awk
    (cd /etc/ccs-gate/design/v0.0.1 && find . -type f ! -name '*.html' -exec sha256sum {} +) > /etc/ccs-gate/design.sha256
    # the proposals repository, with a proposal and the images that may go live (the same
    # qrencode makes them byte for byte on the backend)
    git init -q -b master /srv/proposals && mkdir -p /srv/proposals/images/p && cd /srv/proposals
    echo 'Monero: a guide, in 2 parts.' > p.md
    qrencode -s 4 -o images/p/qr.png 'monero:$(addr 9 B)'
    qrencode -s 4 --foreground=FFFFFF --background=000000 -o images/p/inv.png 'monero:$(addr 9 B)'
    qrencode -s 4 -o images/p/ok.png 'monero:$(addr 2)'
    git add -A && git -c user.name=t -c user.email=t@t commit -q -m proposal && cd /
    chown -R ccs-data /srv/proposals   # git reads a local repository only as its owner
    printf 'PROPOSALS_GIT=file:///srv/proposals\nLINK_HOSTS=forge.test/ccs-proposals\n' > /etc/ccs-gate/proposals.conf
    chmod -R a+rX /etc/ccs-gate && chmod 644 /etc/ccs-gate/*.* /etc/ccs-gate/allowed
    install -d -m 755 $keys
    echo 'from=\"$backend\",command=\"/usr/local/bin/ccs-receive\",restrict $key' > $keys/ccs-data
    chmod 644 $keys/ccs-data
    $sshd
"
on backend "echo '$web $(on web "cat $hostkey")' > ~/.ssh/known_hosts"
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
# site N ADDRESS [QR [IDEA TITLE...]]: the backend's site, version N (the home page's count), a
# proposal with ADDRESS in its donation box and a QR code of QR (default ADDRESS), the ideas,
# projects.json, the design's stylesheet and the signed list's files. Each version gets its own
# file times: two made in the same second, the same size, rsync would skip as unchanged.
qr64() { on backend "qrencode -s ${2:-10} -o - 'monero:$1' | base64 -w0"; }
site() {
    local v=$1 a=$2 qr
    qr=$(qr64 "${3:-$a}")
    shift $(($# < 3 ? $# : 3))
    on backend "rm -rf /out && mkdir -p /out/assets && cp /design/assets/style.css /out/assets/"
    docker exec -e PENDING_NOTE="${PENDING_NOTE:-}" -e ONION="${ONION:-}" "$name-backend" python3 /gen.py /design /out "$v" "$a" "$qr" "$@"
    on backend "echo '[{\"address\": \"$a\"}]' > /out/projects.json"
    put subaddresses.txt < <(on web 'cat /etc/ccs-gate/subaddresses.txt')
    put subaddresses.txt.asc <<<sig
    put subaddresses.txt.key.asc <<<key
    on backend "find /out -exec touch -d @\$((1700000000 + $v * 100)) {} +"
}
# put FILE: stdin as the backend's /out/FILE
put() { docker exec -i "$name-backend" sh -c "mkdir -p \"\$(dirname '/out/$1')\" && cat > '/out/$1'"; }
# change FILE OLD NEW: OLD (its first) made NEW in the backend's /out/FILE, a new time on it
change() {
    docker exec "$name-backend" python3 -c '
import sys; p, a, b = sys.argv[1:]; s = open(p, encoding="utf-8").read(); assert a in s, a
open(p, "w", encoding="utf-8").write(s.replace(a, b, 1))' "/out/$1" "$2" "$3"
    on backend "touch '/out/$1'"
}
push() { on backend "rsync -a --checksum --delay-updates -e 'ssh -o BatchMode=yes -o StrictHostKeyChecking=yes' /out/ ccs-data@$web: 2>&1"; }
live() { on web "sed -n '/<!-- ccs:count fr -->/{n;p}' /var/lib/ccs-data/index.html 2> /dev/null"; }
livefile() { on web "cat '/var/lib/ccs-data/$1' 2> /dev/null || true"; }
livepage() { livefile proposals/p.html; }

site 1 "$(addr 1)"
if out=$(push) && [[ $(live) == 1 ]]; then ok "a push with the wallet's addresses, the design's pages filled, goes live"; else echo "$out"; on web 'tail -n 5 /var/log/ccs-gate.log'; fail "a good push"; fi
# file modes don't go live: a page pushed 600 (a 403 for visitors, and no alert) is 644 there
on backend "chmod 600 /out/index.html && chmod 700 /out/assets"
if push > /dev/null && [[ $(on web "stat -c %a /var/lib/ccs-data/index.html /var/lib/ccs-data/assets" | tr '\n' ' ') == "644 755 " ]]; then
    ok "file modes from the backend don't go live (files 644, folders 755)"
else on web "ls -la /var/lib/ccs-data /var/lib/ccs-data/assets"; fail "file modes"; fi
on backend "chmod 644 /out/index.html && chmod 755 /out/assets"
# only what a push changed is checked: the same site again (nothing), then one page changed
checking() { on web "grep 'checking ' /var/log/ccs-gate.log | tail -n 1"; }
push > /dev/null
if [[ $(checking) == *"checking 0 of "* ]]; then ok "the same site pushed again: nothing to check"; else checking; fail "the same site pushed again"; fi
change index.html $'fr -->\n1\n' $'fr -->\n11\n'
if push > /dev/null && [[ $(live) == 11 && $(checking) == *"checking 1 of "* ]]; then ok "one page changed: that page checked, and only it"; else checking; fail "one page changed"; fi

site 2 "$(addr 9 B)"
# The reason is written after rsync is done: the backend gets it only if ssh relays it before the
# rsync client exits (a race). The push failing and the web server's log are what's certain.
rc=0; out=$(push) || rc=$?
if ((rc)) && [[ $(live) == 2 && $(livepage) == *"$(addr 1)"* && $(livepage) != *"$(addr 9 B)"* ]] \
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

good=$(addr 2) fake=$(addr 9 B)
# a foreign address its checksum says is one (testnet's prefix, random keys), with the gate's own
# Keccak (checked against Keccak-256's of nothing), and it in groups of four
grouped=$(python3 - "$here/../contrib/ccs-receive" <<'PY'
import os, sys
src = open(sys.argv[1]).read().split("check_py='", 1)[1].split("\n'\n", 1)[0]
ns = {}; exec(src[src.index("M = (1 << 64)"):src.index("def valid(")], ns)
assert ns["keccak"](b"").hex() == "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470"
d = bytes([53]) + os.urandom(64); d += ns["keccak"](d)[:4]; a = ""
for i in range(0, len(d), 8):
    n, t = int.from_bytes(d[i:i + 8], "big"), ""
    for _ in range({8: 11, 5: 7}[len(d[i:i + 8])]): n, r = divmod(n, 58); t = ns["B58"][r] + t
    a += t
print(" ".join(a[i:i + 4] for i in range(0, len(a), 4)), end="")
PY
)
integrated=$(printf '4%0105d' 7 | tr 0 1)
held() {
    local rc=0
    push > /dev/null || rc=$?
    if ((rc == 7)) && [[ $(live) == "$1" && $(livefile "$2") != *"$4"* ]]; then ok "held back: $3"; else echo "push exit $rc, live $(live)"; on web 'tail -n 3 /var/log/ccs-gate.log'; fail "$3"; fi
}
passes() {
    local rc=0
    push > /dev/null || rc=$?
    if ((!rc)) && [[ $(live) == "$1" && $(livefile "$2") == *"$4"* ]]; then ok "goes live: $3"; else echo "push exit $rc, live $(live)"; on web 'tail -n 3 /var/log/ccs-gate.log'; fail "$3"; fi
}
v=10
# an address drawn without its own characters, in a name: its two halves in bidi embeddings, a
# space between them shown first (logically "half2 half1", seen as " half1half2"); in
# mathematical sans-serif letters and digits (NFKC turns them into the address)
bidi=$(python3 -c 'import sys; a = sys.argv[1]; print("\u202b\u202a" + a[48:] + "\u202c\u202a " + a[:48] + "\u202c\u202c", end="")' "$fake")
math=$(python3 -c 'import sys; print("".join(chr(0x1D7E2 + int(c)) if c.isdigit() else chr(0x1D5A0 + ord(c) - 65) if c.isupper() else chr(0x1D5BA + ord(c) - 97) for c in sys.argv[1]), end="")' "$fake")
# The ways around it: each a change to a page that is otherwise the design's, filled. That page
# keeps its last good copy, the rest of the push goes live, the push fails.
p=proposals/p.html
box="<div class=\"address\">$good</div>"
# a donation not yet counted (in the pool, or short of MIN_CONFIRMATIONS): ccs-front-bash's note
# beside the total, as the design's donate part has its slot
v=$((v + 1)); PENDING_NOTE=" · 0.01 XMR pending" site "$v" "$good"
passes "$v" "$p" "a donation pending, its note beside the total" "XMR · 0.01 XMR pending"
for attack in \
    "new page|proposals/sneaky.html||<p>pay $fake here</p>|a new page the design doesn't have, with another address" \
    "body|$p|<p>Monero: a guide|<p>Pay $fake: a guide|another proposal text than the repository's" \
    "split|$p|<p>Monero: a guide|<p>${fake:0:40}<span></span>${fake:40} a guide|an address split by markup, in the proposal's text" \
    "zeroimg|$p|<p>Monero: a guide|<p>${fake:0:40}<img src=\"x.png\" width=\"0\" height=\"0\" alt=\"-\">${fake:40} a guide|an address split by an invisible image's alt text" \
    "br|$p|<h1>A proposal</h1>|<h1>A proposal</h1><p>${fake:0:48}<br>${fake:48}</p>|halves of an address either side of a <br>" \
    "outside|$p|<div class=\"body\">|<p>Pay here</p><div class=\"body\">|a paragraph outside any region" \
    "hiddenclass|$p|$box|<div class=\"address\">${good:0:40}<span class=\"visually-hidden\">x</span>${good:40}</div>|text in the donation box the design's classes could hide" \
    "nbsp|$p|<h1>A proposal</h1>|<h1>Option"$'\xc2\xa0'"$fake</h1>|an address after a no-break space, in a name (no address-long run in a name)" \
    "emdash|$p|<h1>A proposal</h1>|<h1>$fake"$'\xe2\x80\x94'"1</h1>|an address before an em dash and a digit, in a name" \
    "zwsp|$p|<h1>A proposal</h1>|<h1>${fake:0:40}"$'\xe2\x80\x8b'"${fake:40}</h1>|an address split by a zero-width space, in a name" \
    "entity|$p|$box|<div class=\"address\">&#$(printf '%d' "'${fake:0:1}");${fake:1}</div>|an address with an HTML entity in it" \
    "integrated|$p|<h1>A proposal</h1>|<h1>$integrated</h1>|an integrated address (106 characters)" \
    "qr|$p|$box|$box|the right address, the QR code of another" \
    "small|$p|$box|$box|the wallet's QR code, but not as qrencode -s 10 makes it" \
    "link|ideas/index.html|https://forge.test/ccs-proposals/pulls/0|https://evil.example/pr/0|a link to another site than the proposals' forge" \
    "otherrepo|ideas/index.html|https://forge.test/ccs-proposals/pulls/0|https://forge.test/someone/else/pulls/0|a link to another repository on the proposals' forge" \
    "dotdot|ideas/index.html|https://forge.test/ccs-proposals/pulls/0|https://forge.test/ccs-proposals/../someone/else|a link that steps out of the proposals repository (..)" \
    "issue|ideas/index.html|https://forge.test/ccs-proposals/pulls/0|https://forge.test/ccs-proposals/issues/1|a link to an issue in the proposals repository, not its merge request" \
    "style|$p|<h1>A proposal</h1>|<h1 style=\"display:none\">A proposal</h1>|a style attribute" \
    "svg|$p|<h1>A proposal</h1>|<h1>A proposal</h1><svg><text>x</text></svg>|an <svg>" \
    "art|$p|<div class=\"body\">|<pre>"$'\xe2\x96\x88\xe2\x96\x80'"</pre><div class=\"body\">|a QR code drawn as text" \
    "monerolink|$p|href=\"monero:$good\"|href=\"monero:${good}x\"|a monero: link with more than an address" \
    "bidi|$p|<h1>A proposal</h1>|<h1>Pay $bidi</h1>|an address in bidi embeddings, a space between its halves shown before them, in a name" \
    "math|$p|<h1>A proposal</h1>|<h1>Pay $math</h1>|an address in mathematical letters, in a name" \
    "grouped|$p|<h1>A proposal</h1>|<h1>Send to $grouped</h1>|an address in groups of four, in a name" \
    "groupedidea|ideas/index.html|An idea|Send to ${grouped// /-}|an address in groups split by -, in an idea's title" \
    "date|ideas/index.html|October 1, 2026|October 1, 2026 and see the new address on the forum|text in a date" \
    "allowedbox|$p|href=\"monero:$fund\"|href=\"monero:$fund\"|a donation box with an allowed address that isn't the wallet's (the General Fund)" \
    "milestone|$p|<p class=\"empty\">No milestones.</p>|<div class=\"milestone\"><h3>Donations moved: see the Verify page</h3><p>10 XMR</p></div>|a milestone the proposal's front matter doesn't have"; do
    IFS='|' read -r what file old new why <<<"$attack"
    v=$((v + 1))
    case $what in
        qr) site "$v" "$good" "$fake" ;;
        small) site "$v" "$good"; change "$file" "$(qr64 "$good")" "$(qr64 "$good" 4)" ;;
        link | otherrepo | dotdot | issue | groupedidea | date) site "$v" "$good" "$good" "An idea" ;;
        allowedbox) site "$v" "$fund" ;;
        *) site "$v" "$good" ;;
    esac
    case $what in
        "new page") put "$file" <<<"$new"; held "$v" "$file" "$why" "$fake" ;;
        qr) held "$v" "$file" "$why" "$(qr64 "$fake")" ;;
        small) held "$v" "$file" "$why" "$(qr64 "$good" 4)" ;;
        *) [[ $old == "$new" ]] || change "$file" "$old" "$new"; held "$v" "$file" "$why" "$new" ;;
    esac
done
# what only a gate that reads too much would hold back: these go live
for title in "Keep running the monero seed nodes for the next twenty four months starting in March and then a few more years" "Research data: an analysis" "Fix charset=latin1 in the docs" $'\xf0\x9f\x9f\xa2 Green light for X' $'\xe2\x96\xb6 Video tutorials' "R&D, <b>bold</b> and a=monero: in a title"; do
    v=$((v + 1)); site "$v" "$good" "$good" "$title"
    passes "$v" ideas/index.html "an idea titled \"$title\" (anyone can open one)" "$(python3 -c 'import html, sys; print(html.escape(sys.argv[1]))' "$title")"
done
# ---- review 5 ----
# G3 residual: a foreign address (synthetic testnet, valid by its checksum) in groups split by
# separators other than spaces or one of . _ : - ; in an idea's title (anyone's) and in a name
taddr=9uH2Z776LeJ4gku967Y3o8VrBueTqSoQhDXVftRkU2Jt81du8DDNV4eAFmPaojQV4mhrgDBvzUfRX7EoHp245dNf9wimfPf
tgroups() { python3 -c 'import sys; a = sys.argv[1]; print(sys.argv[2].join(a[i:i + 4] for i in range(0, 95, 4)), end="")' "$taddr" "$1"; }
for sep in ' - ' ', ' ' | ' '/'; do
    v=$((v + 1)); site "$v" "$good" "$good" "Send to $(tgroups "$sep")"
    held "$v" ideas/index.html "review 5: an address in groups split by '$sep', in an idea's title" "$(tgroups "$sep" | python3 -c 'import html, sys; print(html.escape(sys.stdin.read()), end="")')"
done
v=$((v + 1)); site "$v" "$good"; change "$p" "<h1>A proposal</h1>" "<h1>Send to $(tgroups ' - ')</h1>"
held "$v" "$p" "review 5: an address in groups split by ' - ', in a name" "$(tgroups ' - ')"
# ... and in projects.json, its groups split by a JSON escaped space (json_py reads no groups; scan_py reads the raw text)
v=$((v + 1)); site "$v" "$good"
put projects.json <<<"[{\"address\": \"$good\", \"title\": \"Send to $(tgroups "$(printf '\x5cu0020')")\"}]"
held "$v" projects.json "review 5: an address in groups split by \\u0020 in a projects.json string" 'Send to'
on web "grep projects.json /var/log/ccs-gate.log | tail -n 1"
# cost: 100 ideas titled "AAAA AAAA ..." (255 characters, anyone's): every window of the joined
# run passes valid()'s network-byte check, so each costs a Keccak in Python; scan_py has 120 s for
# every page of the site together, and past that holds back every page
v=$((v + 1)); mapfile -t many < <(for i in $(seq 100); do printf 'AAAA %.0s' {1..51}; echo; done)
site "$v" "$good" "$good" "${many[@]}"
start=$SECONDS; rc=0; push > /dev/null || rc=$?
if ((SECONDS - start < 30)) && ((rc == 0)); then ok "review 5: 100 ideas titled AAAA AAAA...: checked in $((SECONDS - start))s"; else fail "review 5: 100 ideas titled AAAA AAAA... (anyone's): the push took $((SECONDS - start))s (exit $rc); scan_py's 120 s is for every page together"; fi
# ... the same on a web server with a third of a CPU (node2 also runs monerod and more): past
# scan_py's 120 s every page of the push is held back, the home page too
docker update --cpus 0.33 "$name-web" > /dev/null
v=$((v + 1)); site "$v" "$good" "$good" "${many[@]}"
start=$SECONDS; rc=0; push > /dev/null || rc=$?
if [[ $(live) == "$v" ]]; then ok "review 5: 100 such ideas, a third of a CPU: the home page still goes live ($((SECONDS - start))s, exit $rc)"
else on web 'grep -c "could not be read in time" /var/log/ccs-gate.log || true'; fail "review 5: 100 such ideas (anyone's), a third of a CPU: every page held back, the home page too ($((SECONDS - start))s, exit $rc)"; fi
docker update --cpus 0 "$name-web" > /dev/null
# ---- end review 5 ----
# ---- review 5, low ----
# G5 / G7: what reaches a QR decoder. The gate notes each image it reads (its first bytes) in
# its state folder's scan.log, when there is one.
on web 'install -o ccs-data -m 644 /dev/null /var/lib/ccs-gate/scan.log'
v=$((v + 1)); site "$v" "$good"
svg64=$(printf '<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><rect width="10" height="10"/></svg>' | base64 -w0)
change "$p" "$(qr64 "$good")" "$svg64"
held "$v" "$p" "review 5: an SVG as a donation box's QR code" "$svg64"
if on web '! grep -qv "^211PNG png$" /var/lib/ccs-gate/scan.log'; then ok "review 5 (G5): the QR decoder was given only PNGs, as PNGs"; else on web 'sort /var/lib/ccs-gate/scan.log | uniq -c'; fail "review 5 (G5): a file that is not a PNG, from the backend, reached a decoder before any PNG check"; fi
# G7: the same QR code on 5 proposal pages: read once (scan), or once per page (the box check)?
on web 'cd /srv/proposals && for q in q1 q2 q3 q4; do cp p.md $q.md; done && git -c safe.directory=* add -A && git -c safe.directory=* -c user.name=t -c user.email=t@t commit -q -m more && chown -R ccs-data /srv/proposals'
v=$((v + 1)); site "$v" "$good"
on backend 'for q in q1 q2 q3 q4; do cp /out/proposals/p.html /out/proposals/$q.html; done'
on web ': > /var/lib/ccs-gate/scan.log'
push > /dev/null || true
n=$(on web 'grep -c . /var/lib/ccs-gate/scan.log || true')
if ((n <= 2)); then ok "review 5 (G7): one QR code on 5 pages read $n time(s)"; else fail "review 5 (G7): one QR code on 5 pages read $n times (the box check reads it again on each page, with no deadline)"; fi
on web 'rm /var/lib/ccs-gate/scan.log'
on backend 'rm -f /out/proposals/q?.html'
# a folder pushed without read permission: its pages can't be listed by the checks, nor copied
v=$((v + 1)); site "$v" "$good"
on backend "mkdir -p /out/sneak && printf '<p>%s</p>\n' '$taddr' > /out/sneak/index.html && chmod 300 /out/sneak"
rc=0; push > /dev/null || rc=$?
if on web "! grep -rqs '$taddr' /var/lib/ccs-data/sneak"; then ok "review 5: a folder pushed 300: its page does not go live (push exit $rc)"; else fail "review 5: a folder pushed 300: its unchecked page went live"; fi
on backend 'chmod 755 /out/sneak && rm -rf /out/sneak'
v=$((v + 1)); site "$v" "$good"
if push > /dev/null && [[ $(live) == "$v" ]]; then ok "review 5: the next good push after a folder pushed 300 goes live"; else on web 'tail -n 3 /var/log/ccs-gate.log'; fail "review 5: after a folder pushed 300, the next good push does not go live"; fi
# ---- end review 5, low ----
v=$((v + 1)); site "$v" "$good"
put projects.json <<<"[{\"address\": \"$good\", \"title\": \"R&D notes\", \"url\": \"data:text/plain,x\"}]"
passes "$v" projects.json "JSON with & and data: in its text" 'R&D'
# /projects, as JSON: its readers decode \u escapes, and read a key twice as its last
v=$((v + 1)); site "$v" "$good"
put projects.json <<<"[{\"address\": \"${fake:0:1}\\u00$(printf '%x' "'${fake:1:1}")${fake:2}\"}]"
held "$v" projects.json "an address with a \\u escape in projects.json" '\u00'
v=$((v + 1)); site "$v" "$good"
put projects.json <<<"{\"address\": \"$fake\", \"address\": \"$good\"}"
held "$v" projects.json "a key twice in projects.json, another address in the first" "$fake"
# names an rsync exclude pattern can't hold exactly: a backslash with no wildcard, a wildcard, both
for file in 'back\slash' 'star*' 'both\[x]'; do
    v=$((v + 1)); site "$v" "$good"
    put "proposals/$file.html" <<<"<p>$fake</p>"
    held "$v" "proposals/$file.html" "a page named $file.html" "$fake"
done
v=$((v + 1)); site "$v" "$good"; put assets/evil.css <<<'.address::after { content: "x" }'
held "$v" assets/evil.css "a stylesheet that isn't the design's" "content"
v=$((v + 1)); site "$v" "$good"; put assets/style.css <<<'.address { display: none }'
rc=0; push > /dev/null || rc=$?
if ((rc)) && [[ $(live) == "$v" && $(livefile assets/style.css) == 'body {}' ]]; then ok "held back: a design file changed (its last good copy stays)"; else fail "a changed design file"; fi
v=$((v + 1)); site "$v" "$good"; printf '0 %s\n' "$fake" | put subaddresses.txt
rc=0; push > /dev/null || rc=$?
if ((rc)) && [[ $(livefile subaddresses.txt) != *"$fake"* ]]; then ok "held back: a subaddress list that isn't the one installed here"; else fail "a swapped list"; fi
# the footer's onion line: only this site's onion (/etc/ccs-gate/onion), on every page; none
# configured, none at all; another onion, held back, the page's last good copy staying
our=abcdefghijklmnopqrstuvwxyz234567abcdefghijklmnopqrstuvwx.onion other=zyxwvutsrqponmlkjihgfedcba765432zyxwvutsrqponmlkjihgfedc.onion
# (the pages with the line are every page, the home page too: held back, the last good ones stay)
onion_held() {   # onion_held WHAT ONION
    local before rc=0
    before=$(live); v=$((v + 1)); ONION=$2 site "$v" "$good"
    push > /dev/null || rc=$?
    if ((rc == 7)) && [[ $(live) == "$before" && $(livefile index.html) != *"$2"* && $(livefile proposals/p.html) != *"$2"* ]]; then ok "held back: $1"
    else echo "push exit $rc, live $(live)"; on web 'tail -n 3 /var/log/ccs-gate.log'; fail "$1"; fi
}
onion_held "an onion line where this site has no onion configured" "$our"
on web "echo $our > /etc/ccs-gate/onion && chmod 644 /etc/ccs-gate/onion"
v=$((v + 1)); ONION=$our site "$v" "$good"
passes "$v" proposals/p.html "the footer's onion line with this site's onion (/etc/ccs-gate/onion)" "Also on Tor: <a href=\"http://$our/\">$our</a>"
onion_held "an onion line with another onion than this site's" "$other"
v=$((v + 1)); site "$v" "$good"
passes "$v" index.html "no onion line, with one configured" "Funding required"
on web "rm -f /etc/ccs-gate/onion"
v=$((v + 1)); site "$v" "$good"; on backend "qrencode -s 4 -o /tmp/q.png 'monero:$fake'"; docker exec "$name-backend" sh -c 'mkdir -p /out/images/p && cp /tmp/q.png /out/images/p/qr.png'
held "$v" images/p/qr.png "a proposal image that is a QR code of another address" "PNG"
v=$((v + 1)); site "$v" "$good"; docker exec "$name-backend" sh -c "mkdir -p /out/images/p && qrencode -s 4 --foreground=FFFFFF --background=000000 -o /out/images/p/inv.png 'monero:$fake'"
held "$v" images/p/inv.png "a proposal image that is an inverted QR code of another address" "PNG"
v=$((v + 1)); site "$v" "$good"; docker exec "$name-backend" sh -c "mkdir -p /out/images/p && qrencode -s 4 -o /out/images/p/ok.png 'monero:$good'"
if push > /dev/null && [[ $(live) == "$v" ]] && on web 'test -s /var/lib/ccs-data/images/p/ok.png'; then ok "a proposal image with the wallet's QR code goes live"; else fail "a good proposal image"; fi
# an image the proposals repository doesn't have, at that path or at all: half a QR code, say
v=$((v + 1)); site "$v" "$good"; docker exec "$name-backend" sh -c "mkdir -p /out/images/p && qrencode -s 4 -o /out/images/p/half.png 'monero:$good'"
held "$v" images/p/half.png "a proposal image the proposals repository doesn't have" "PNG"
v=$((v + 1)); site "$v" "$good"; docker exec "$name-backend" sh -c "mkdir -p /out/images/q && qrencode -s 4 -o /out/images/q/ok.png 'monero:$good'"
held "$v" images/q/ok.png "a proposal image the repository has, but at another path" "PNG"
on backend 'rm -rf /out/images/q'
v=$((v + 1)); site "$v" "$good"; docker exec "$name-backend" sh -c "mkdir -p /out/images/p && qrencode -s 5 -o /out/images/p/ok.png 'monero:$good'"
rc=0; push > /dev/null || rc=$?
if ((rc)) && [[ $(live) == "$v" ]] && on web 'cmp -s /var/lib/ccs-data/images/p/ok.png /srv/proposals/images/p/ok.png'; then ok "held back: a proposal image changed from the repository's (its last good copy stays)"; else fail "a changed proposal image"; fi
on backend 'rm -rf /out/images'
# a proposal taken out of the repository: its page, left on the live site (the push can't
# delete), goes with its images and the push is good; pushed again by the backend, it is held
# back; while the repository can't be fetched (the last fetch), it stays
# (the proposal taken out is a new commit: every page is checked again then)
stale() {
    on web 'cd /var/lib/ccs-data && cp proposals/p.html proposals/gone.html && mkdir -p images/gone && cp /srv/proposals/images/p/ok.png images/gone/ && chown -R ccs-data proposals/gone.html images'
    on web 'cd /srv/proposals && git -c safe.directory=* -c user.name=t -c user.email=t@t commit -q --allow-empty -m "a proposal taken out" && chown -R ccs-data /srv/proposals'
}
stale
v=$((v + 1)); site "$v" "$good"
if push > /dev/null && [[ $(live) == "$v" ]] && on web '! test -e /var/lib/ccs-data/proposals/gone.html && ! test -e /var/lib/ccs-data/images/gone' \
    && on web "grep -q 'removed proposals/gone.html (and images/gone/, if any) from the site: gone.md is no longer' /var/log/ccs-gate.log"; then
    ok "a proposal taken out of the repository: its page left live goes, with its images; the push is good"
else on web 'tail -n 5 /var/log/ccs-gate.log'; fail "a removed proposal's page"; fi
v=$((v + 1)); site "$v" "$good"; on backend 'cp /out/proposals/p.html /out/proposals/gone.html'
held "$v" proposals/gone.html "a page of a proposal not in the repository, pushed" "no proposal"
on web "sed -i 's#=file:///srv/proposals#=file:///nowhere#' /etc/ccs-gate/proposals.conf"
stale
v=$((v + 1)); site "$v" "$good"
push > /dev/null || true
if on web 'test -e /var/lib/ccs-data/proposals/gone.html'; then ok "the repository can't be fetched: a page with no proposal in the last fetch stays"; else fail "a removed proposal's page, no fetch"; fi
on web 'rm -rf /var/lib/ccs-data/proposals/gone.html /var/lib/ccs-data/images/gone'
on web "sed -i 's#=file:///nowhere#=file:///srv/proposals#' /etc/ccs-gate/proposals.conf"
# more than 3 at once (a branch emptied or rewritten): none taken, an alert, the push fails
on web 'cd /var/lib/ccs-data && for n in 1 2 3 4; do cp proposals/p.html proposals/gone$n.html; done && chown ccs-data proposals/gone*.html'
on web 'cd /srv/proposals && git -c safe.directory=* -c user.name=t -c user.email=t@t commit -q --allow-empty -m "four taken out" && chown -R ccs-data /srv/proposals'
v=$((v + 1)); site "$v" "$good"
rc=0; push > /dev/null || rc=$?
if ((rc == 7)) && on web 'test -e /var/lib/ccs-data/proposals/gone1.html && test -e /var/lib/ccs-data/proposals/gone4.html' \
    && bot | grep -q 'would take 4 proposal pages off the site at once'; then
    ok "four proposal pages in neither commit at once: none taken off the site, IRC told, the push fails"
else on web 'tail -n 5 /var/log/ccs-gate.log'; bot | tail -n 3; fail "many removed at once"; fi
on web 'rm -f /var/lib/ccs-data/proposals/gone[1-4].html'
# the repository can't be fetched: the last fetch is checked against, so the site goes on
on web "sed -i 's#=file:///srv/proposals#=file:///nowhere#' /etc/ccs-gate/proposals.conf"
v=$((v + 1)); site "$v" "$good"
if push > /dev/null && [[ $(live) == "$v" ]] && on web "grep -q 'checking against the last fetch' /var/log/ccs-gate.log" \
    && ! bot | grep -q 'fetch the proposals repository'; then ok "the proposals repository can't be fetched: checked against the last fetch, the site goes on (no alert yet)"; else fail "the repository down"; fi
# and for FORGE_HOURS (default 6) since the last good fetch: one alert an hour; fetched again, says so
on web 'touch -d "-7 hours" /var/lib/ccs-gate/fetch-ok'
v=$((v + 1)); site "$v" "$good"; push > /dev/null || true
v=$((v + 1)); site "$v" "$good"; push > /dev/null || true
if [[ $(bot | grep -c "the web server can't fetch the proposals repository since" || true) == 1 ]] \
    && bot | grep -qE "^\[CCS-watch\] the web server can't fetch the proposals repository since [0-9-]+ [0-9:]+ UTC \(proposals.conf\): a proposal merged or changed since can't go live @ https://ccs.test$"; then
    ok "the repository down for 7 hours: one alert, not one a push"
else
    bot; fail "the repository down for long"
fi
on web "sed -i 's#=file:///nowhere#=file:///srv/proposals#' /etc/ccs-gate/proposals.conf"
v=$((v + 1)); site "$v" "$good"; push > /dev/null || true
v=$((v + 1)); site "$v" "$good"; push > /dev/null || true
if [[ $(bot | grep -c 'the web server fetches the proposals repository again @ https://ccs.test' || true) == 1 ]]; then ok "the repository fetched again: says so, once"; else bot; fail "the repository back"; fi
# what the pages were checked against changes (here allowed, the General Fund in every footer
# taken out of it): every page is checked again, and held back; pushed again unchanged, they are
# checked again (their last good copy is live, the same bytes), until they pass
v=$((v + 1)); site "$v" "$good"; push > /dev/null || true
on web 'cp /etc/ccs-gate/allowed /tmp/allowed && : > /etc/ccs-gate/allowed'
rc1=0; push > /dev/null || rc1=$?; c1=$(checking)
rc2=0; push > /dev/null || rc2=$?; c2=$(checking)
if ((rc1 == 7 && rc2 == 7)) && [[ $c1 == *"(all of them"* && $c2 != *"(all of them"* && $c2 != *"checking 0 of"* ]]; then
    ok "allowed changed: every page checked again; held back, the same pages pushed again are checked again"
else echo "$c1 / $c2 (exits $rc1 $rc2)"; fail "allowed changed"; fi
on web 'cp /tmp/allowed /etc/ccs-gate/allowed'
rc=0; push > /dev/null || rc=$?
if ((rc == 0)) && [[ $(checking) == *"(all of them"* ]]; then ok "allowed as before: every page checked again, the push good"; else checking; fail "allowed restored"; fi
# and once a day whatever happens
on web 'touch -d "-25 hours" /var/lib/ccs-gate/checked-with'
if push > /dev/null && [[ $(checking) == *"(all of them"* ]]; then ok "a day after the last full check: every page checked again"; else checking; fail "the daily full check"; fi
# a NUL byte, which HTML drops from the text
v=$((v + 1)); site "$v" "$good"; on backend "printf '<p>%s\\000%s</p>\\n' '${fake:0:40}' '${fake:40}' > /out/proposals/nul.html"
held "$v" proposals/nul.html "an address split by a NUL byte" "${fake:40}"
# an image named as a page: a browser shows <img src="x.html"> by its bytes
v=$((v + 1)); site "$v" "$good"; on backend "qrencode -s 10 -o /out/proposals/img.html 'monero:$fake'"
held "$v" proposals/img.html "a PNG named .html" "PNG"
v=$((v + 1)); site "$v" "$good"; on backend "qrencode -s 10 -o /out/projects.json 'monero:$fake'"
rc=0; push > /dev/null || rc=$?
if ((rc)) && [[ $(live) == "$v" && $(livefile projects.json) == '[{'* ]]; then ok "held back: a PNG as projects.json (its last good copy stays)"; else fail "a PNG as projects.json"; fi
# a good QR code with more beside it: the QR reader reads the good one, the rest is another's
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
change "$p" "$(qr64 "$good")" "$(on backend 'cat /tmp/two.b64')"
# (read on the backend by the gate's own reader, ccs-receive's qrscan_py)
qrpy=$(sed -n "/^qrscan_py='/,/^'\$/p" "$here/../contrib/ccs-receive" | sed "1s/^qrscan_py='//; \$d")
if on backend 'base64 -d /tmp/two.b64 > /tmp/two.png' && docker exec "$name-backend" python3 -I -c "$qrpy" png /tmp/two.png | grep -qx "monero:$good"; then held "$v" "$p" "a good QR code with more drawn beside it" "$(on backend 'cat /tmp/two.b64')"; else fail "the two-part test image doesn't read"; fi
# two pushes at once: the second waits for the first (one staging folder, one at a time)
v=$((v + 1)); site "$v" "$good"
on backend "(rsync -a -e 'ssh -o BatchMode=yes' /out/ ccs-data@$web: > /tmp/a 2>&1; echo \$? >> /tmp/a) & (rsync -a -e 'ssh -o BatchMode=yes' /out/ ccs-data@$web: > /tmp/b 2>&1; echo \$? >> /tmp/b) & wait"
if [[ $(on backend 'tail -n 1 /tmp/a; tail -n 1 /tmp/b') == $'0\n0' && $(live) == "$v" ]]; then ok "two pushes at once both go through, one after the other"; else on backend 'cat /tmp/a /tmp/b'; fail "two pushes at once"; fi

v=$((v + 1)); site "$v" "$(addr 2)"
if push > /dev/null && [[ $(live) == "$v" ]]; then ok "the next good push goes live again"; else fail "recovery"; fi
last=$v

# (a design folder not named as a release, vX.Y.Z: a build of the design's left there, is none)
for missing in "design/v0.0.1|design release|/tmp/moved" "design/v0.0.1|design release, but a build of it named dev-1|/etc/ccs-gate/design/dev-1" \
    "markdown.awk|markdown.awk|/tmp/moved"; do
    IFS='|' read -r f what to <<<"$missing"
    on web "mv /etc/ccs-gate/$f $to && : > /var/log/ccs-gate.log"
    v=$((v + 1)); site "$v" "$(addr 2)"
    if ! push > /dev/null && [[ $(live) == "$last" ]] && on web "grep -q 'refused the push: it has no /etc/ccs-gate/' /var/log/ccs-gate.log"; then
        ok "no $what installed: every push refused"
    else
        fail "no $what"
    fi
    on web "mv $to /etc/ccs-gate/$f"
done

on web "echo '3 $(addr 3)' >> /etc/ccs-gate/subaddresses.txt"
v=$((v + 1)); site "$v" "$(addr 3)"
if ! out=$(push) && [[ $(live) == "$last" && $out == *"is not the list"*".pin names"* ]] \
    && bot | grep -qF "[CCS-watch] the web server refuses every push: its signed list isn't the one its .pin names"; then ok "a list that isn't the pinned one: every push refused"; else echo "$out"; fail "a changed list"; fi

# rrsync's limits still hold through the gate: no deleting, nothing outside its folder
on web "echo keep > /var/lib/ccs-data/keep.txt"
v=$((v + 1)); site "$v" "$(addr 2)"
on backend "rsync -a --delete -e 'ssh -o BatchMode=yes' /out/ ccs-data@$web: > /dev/null 2>&1" || true
on backend "echo x > /tmp/x && rsync -e 'ssh -o BatchMode=yes' /tmp/x ccs-data@$web:../../../tmp/escaped > /dev/null 2>&1" || true
if [[ $(on web 'cat /var/lib/ccs-data/keep.txt') == keep ]] && ! on web 'test -e /tmp/escaped || test -e /var/lib/escaped'; then
    ok "no deleting and nothing outside the folder, through the gate too"
else
    fail "rrsync's limits"
fi

# the key still runs nothing but the gate
if ! grep -q root <<<"$(on backend "ssh -o BatchMode=yes ccs-data@$web 'cat /etc/passwd' 2>&1")"; then ok "the key runs nothing else"; else fail "the key ran a command"; fi
# the heartbeat: pushes are the backend's; the web server's timer alerts when none arrive
hb() { docker exec -u "$data" "$name-web" /usr/local/bin/ccs-receive --heartbeat; }
late() { bot | grep -c 'no push from the backend' || true; }
on web "printf 'sha256 %s\nkey %040d\n' \"\$(sha256sum < /etc/ccs-gate/subaddresses.txt | cut -d' ' -f1)\" 0 > /etc/ccs-gate/subaddresses.txt.pin"   # the list above, pinned again
on web 'rm -f /var/lib/ccs-data/keep.txt'   # root's, from the test above: ccs-data can't copy it
v=$((v + 1)); site "$v" "$(addr 2)"
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
v=$((v + 1)); site "$v" "$(addr 2)"
push > /dev/null
hb
if bot | grep -qF '[CCS-watch] pushes from the backend arrive again @ https://ccs.test'; then ok "heartbeat: pushes arrive again, IRC is told"; else bot; fail "heartbeat recovery"; fi
on web 'rm -f /var/lib/ccs-gate/last-push /var/lib/ccs-gate/alert-heartbeat'
hb
if [[ $(late) == 1 ]]; then ok "heartbeat: before any push, nothing is known: no alert"; else fail "heartbeat without a push"; fi

# a page made to be costly to check: a name of 4 million spaces (unbounded, it cost the page check
# 600 MB; padded otherwise, more than its 300 s), the web server given 400 MB. Held back, its
# address split by markup after the name too.
docker update --memory 400m --memory-swap 400m "$name-web" > /dev/null
v=$((v + 1)); site "$v" "$good"
docker exec "$name-backend" python3 -c '
import sys; p = "/out/proposals/p.html"; s = open(p, encoding="utf-8").read()
s = s.replace("<h1>A proposal</h1>", "<h1>A proposal" + " " * 4000000 + "</h1>" + sys.argv[1], 1)
open(p, "w", encoding="utf-8").write(s)' "<p>${fake:0:40}<span></span>${fake:40}</p>"
held "$v" "$p" "a page too big to check, with an address split by markup" "${fake:0:40}<span></span>"
docker update --memory 8g --memory-swap 8g "$name-web" > /dev/null
# a page made a folder: the live page must keep its last good copy (rrsync -no-del)
v=$((v + 1)); site "$v" "$good"
on backend 'rm /out/ideas/index.html && mkdir /out/ideas/index.html && touch /out/ideas/index.html/.keep'
push > /dev/null || true
if on web 'test -f /var/lib/ccs-data/ideas/index.html'; then ok "held back: a page made a folder (its last good copy stays)"; else fail "a page made a folder: the live page is gone"; fi
# every page held back so far was held for a reason it states: none of them "could not check"
if on web "! grep -q 'a page the gate could not check' /var/log/ccs-gate.log"; then ok "a page held back for a reason gives that reason only (not \"could not check\")"; else on web "grep 'could not check' /var/log/ccs-gate.log | head -n 3"; fail "a held page also said \"could not check\""; fi
# the page check stopping (here: its cache of the proposals' texts broken) holds back every page,
# not only the ones it got to: what isn't known good doesn't go live
v=$((v + 1)); site "$v" "$good"
on web 'for f in /var/lib/ccs-gate/bodies-*.jsonl; do echo "{not json" > "$f"; done'
rc=0; push > /dev/null || rc=$?
if ((rc == 7)) && [[ $(live) != "$v" ]] && on web "grep -q 'a page the gate could not check' /var/log/ccs-gate.log"; then ok "the page check stopping: every page held back"; else echo "push exit $rc, live $(live)"; fail "the page check stopping: pages went live unchecked"; fi
on web 'rm -f /var/lib/ccs-gate/bodies-*.jsonl'
# a backend that hangs up while the gate checks its push: the gate must still tell IRC what it held back
v=$((v + 1)); site "$v" "$good"
put proposals/probe.html <<<"<p>$(addr 5 C)</p>"
alerts=$(bot | grep -c . || true)
before=$(on web 'stat -c %Y /var/lib/ccs-gate/last-push 2> /dev/null || echo 0')
on backend "rsync -a --delay-updates -e 'ssh -o BatchMode=yes' /out/ ccs-data@$web: > /dev/null 2>&1 &"
# received (the gate stamps last-push once rrsync is done): hang up while it checks
for _ in $(seq 100); do [[ $(on web 'stat -c %Y /var/lib/ccs-gate/last-push 2> /dev/null || echo 0') != "$before" ]] && break; sleep 0.1; done
on backend 'pkill -x ssh || true'
for _ in $(seq 100); do on web 'for p in /proc/[0-9]*/cmdline; do { tr "\0" " " < $p; } 2> /dev/null; echo; done | grep -q "[c]cs-receive"' || break; sleep 0.2; done
if (($(bot | grep -c . || true) > alerts)); then ok "a backend that hangs up mid-check: the gate still alerts"; else on web 'tail -n 3 /var/log/ccs-gate.log'; fail "a backend that hangs up mid-check: no alert from the gate"; fi

exit "$status"

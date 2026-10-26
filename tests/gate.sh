#!/usr/bin/env bash
# The web server's gate (contrib/ccs-receive, docs/two-machines.md): a web server set up as
# documented and a backend, in containers, with a small design in the release zip's shape (its
# pages and parts) and a proposals repository. A good push goes live; a page that isn't the
# design's filled as ccs-front-bash fills it, an address that is neither the wallet's nor allowed,
# or a list that isn't the pinned one, leaves the live file as it was and says why. Needs docker
# and network.
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

# The design: pages with regions, parts with {{slots}}, as ccs-front-hugo's release zip has them
# (its README: "What ccs-front-bash fills in"); the General Fund in every page's footer.
d=$files/design
mkdir -p "$d/parts" "$d/ideas" "$d/assets"
foot="<footer><p class=\"address\">$fund</p></footer>"
printf '<!doctype html>\n<html lang="en">\n<head><meta charset="utf-8"><title>CCS</title><link rel="stylesheet" href="./assets/style.css"></head>\n<body>\n<p>Funding required: <!-- ccs:count fr -->\n0\n<!-- /ccs:count fr --></p>\n<!-- ccs:filters -->\n<!-- /ccs:filters -->\n%s\n</body>\n</html>\n' "$foot" > "$d/index.html"
printf '<!doctype html>\n<html lang="en">\n<head><meta charset="utf-8"><title>Ideas</title></head>\n<body>\n<!-- ccs:list idea -->\n<!-- /ccs:list idea -->\n%s\n</body>\n</html>\n' "$foot" > "$d/ideas/index.html"
printf '<!doctype html>\n<html lang="en">\n<head><meta charset="utf-8"><title>{{name}}</title></head>\n<body>\n<h1>{{name}}</h1>\n<p class="by">{{author}} {{tag_links}}</p>\n<!-- ccs:%s -->\n<!-- /ccs:%s -->\n<div class="body">\n{{body}}\n</div>\n<!-- ccs:milestones -->\n<!-- /ccs:milestones -->\n%s\n</body>\n</html>\n' donate donate "$foot" > "$d/parts/proposal-fr.html"
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
    os.makedirs(os.path.dirname(out + "/" + p), exist_ok=True); open(out + "/" + p, "w", encoding="utf-8").write(t)
write("index.html", region(region(read(design + "/index.html"), "count fr", n), "filters", ""))
cards = [fill(part("card-idea"), {"url": "https://forge.test/ccs-proposals/pulls/%d" % i, "name": html.escape(t), "author": "someone",
         "date": "October 1, 2026", "funding_note": "", "tags": "", "upvotes": "1", "downvotes": "0"}) for i, t in enumerate(sys.argv[6:])]
write("ideas/index.html", region(read(design + "/ideas/index.html"), "list idea", "\n".join(cards) or part("empty")))
page = fill(read(design + "/parts/proposal-fr.html"), {"name": "A proposal", "author": "someone", "tag_links": "",
             "body": "<p>Monero: a guide, in 2 parts.</p>"})
page = region(page, "donate", fill(part("donate"), {"raised": "1.5", "amount": "10", "pending_note": "", "address": addr,
             "qr": "data:image/png;base64," + qr, "verify_link": read(design + "/parts/verify-link.html").rstrip("\n")}))
write("proposals/p.html", region(page, "milestones", part("no-milestones")) + "\n")
PY

on backend 'mkdir -p ~/.ssh && ssh-keygen -q -t ed25519 -N "" -f ~/.ssh/id_ed25519'
key=$(on backend 'cat ~/.ssh/id_ed25519.pub')
docker cp "$here/../contrib/ccs-receive" "$name-web:/usr/local/bin/ccs-receive"
docker cp "$d" "$name-web:/tmp/design" && docker cp "$files/markdown.awk" "$name-web:/tmp/markdown.awk"
docker cp "$d" "$name-backend:/design" && docker cp "$files/gen.py" "$name-backend:/gen.py"
on web "
    chown root:root /usr/local/bin/ccs-receive && chmod 755 /usr/local/bin/ccs-receive
    useradd --system --create-home --shell /bin/sh ccs-data
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
    cp -r /tmp/design /etc/ccs-gate/design/test && cp /tmp/markdown.awk /etc/ccs-gate/markdown.awk
    (cd /etc/ccs-gate/design/test && find . -type f ! -name '*.html' -exec sha256sum {} +) > /etc/ccs-gate/design.sha256
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
    docker exec "$name-backend" python3 /gen.py /design /out "$v" "$a" "$qr" "$@"
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
push() { on backend "rsync -a --delay-updates -e 'ssh -o BatchMode=yes -o StrictHostKeyChecking=yes' /out/ ccs-data@$web: 2>&1"; }
live() { on web "sed -n '/<!-- ccs:count fr -->/{n;p}' /var/lib/ccs-data/index.html 2> /dev/null"; }
livefile() { on web "cat '/var/lib/ccs-data/$1' 2> /dev/null || true"; }
livepage() { livefile proposals/p.html; }

site 1 "$(addr 1)"
if out=$(push) && [[ $(live) == 1 ]]; then ok "a push with the wallet's addresses, the design's pages filled, goes live"; else echo "$out"; on web 'tail -n 5 /var/log/ccs-gate.log'; fail "a good push"; fi

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
    "style|$p|<h1>A proposal</h1>|<h1 style=\"display:none\">A proposal</h1>|a style attribute" \
    "svg|$p|<h1>A proposal</h1>|<h1>A proposal</h1><svg><text>x</text></svg>|an <svg>" \
    "art|$p|<div class=\"body\">|<pre>"$'\xe2\x96\x88\xe2\x96\x80'"</pre><div class=\"body\">|a QR code drawn as text" \
    "monerolink|$p|href=\"monero:$good\"|href=\"monero:${good}x\"|a monero: link with more than an address" \
    "bidi|$p|<h1>A proposal</h1>|<h1>Pay $bidi</h1>|an address in bidi embeddings, a space between its halves shown before them, in a name" \
    "math|$p|<h1>A proposal</h1>|<h1>Pay $math</h1>|an address in mathematical letters, in a name" \
    "allowedbox|$p|href=\"monero:$fund\"|href=\"monero:$fund\"|a donation box with an allowed address that isn't the wallet's (the General Fund)" \
    "milestone|$p|<p class=\"empty\">No milestones.</p>|<div class=\"milestone\"><h3>Donations moved: see the Verify page</h3><p>10 XMR</p></div>|a milestone the proposal's front matter doesn't have"; do
    IFS='|' read -r what file old new why <<<"$attack"
    v=$((v + 1))
    case $what in
        qr) site "$v" "$good" "$fake" ;;
        small) site "$v" "$good"; change "$file" "$(qr64 "$good")" "$(qr64 "$good" 4)" ;;
        link | otherrepo | dotdot) site "$v" "$good" "$good" "An idea" ;;
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
for title in "Research data: an analysis" "Fix charset=latin1 in the docs" $'\xf0\x9f\x9f\xa2 Green light for X' $'\xe2\x96\xb6 Video tutorials' "R&D, <b>bold</b> and a=monero: in a title"; do
    v=$((v + 1)); site "$v" "$good" "$good" "$title"
    passes "$v" ideas/index.html "an idea titled \"$title\" (anyone can open one)" "$(python3 -c 'import html, sys; print(html.escape(sys.argv[1]))' "$title")"
done
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
# the repository can't be fetched: the last fetch is checked against, so the site goes on
on web "sed -i 's#=file:///srv/proposals#=file:///nowhere#' /etc/ccs-gate/proposals.conf"
v=$((v + 1)); site "$v" "$good"
if push > /dev/null && [[ $(live) == "$v" ]] && on web "grep -q 'checking against the last fetch' /var/log/ccs-gate.log"; then ok "the proposals repository can't be fetched: checked against the last fetch, the site goes on"; else fail "the repository down"; fi
on web "sed -i 's#=file:///nowhere#=file:///srv/proposals#' /etc/ccs-gate/proposals.conf"
# a NUL byte, which HTML drops from the text
v=$((v + 1)); site "$v" "$good"; on backend "printf '<p>%s\\000%s</p>\\n' '${fake:0:40}' '${fake:40}' > /out/proposals/nul.html"
held "$v" proposals/nul.html "an address split by a NUL byte" "${fake:40}"
# an image named as a page: a browser shows <img src="x.html"> by its bytes
v=$((v + 1)); site "$v" "$good"; on backend "qrencode -s 10 -o /out/proposals/img.html 'monero:$fake'"
held "$v" proposals/img.html "a PNG named .html" "PNG"
v=$((v + 1)); site "$v" "$good"; on backend "qrencode -s 10 -o /out/projects.json 'monero:$fake'"
rc=0; push > /dev/null || rc=$?
if ((rc)) && [[ $(live) == "$v" && $(livefile projects.json) == '[{'* ]]; then ok "held back: a PNG as projects.json (its last good copy stays)"; else fail "a PNG as projects.json"; fi
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
change "$p" "$(qr64 "$good")" "$(on backend 'cat /tmp/two.b64')"
if on backend 'base64 -d /tmp/two.b64 > /tmp/two.png && zbarimg -q --raw /tmp/two.png' | grep -qx "monero:$good"; then held "$v" "$p" "a good QR code with more drawn beside it" "$(on backend 'cat /tmp/two.b64')"; else fail "the two-part test image doesn't read"; fi
# two pushes at once: the second waits for the first (one staging folder, one at a time)
v=$((v + 1)); site "$v" "$good"
on backend "(rsync -a -e 'ssh -o BatchMode=yes' /out/ ccs-data@$web: > /tmp/a 2>&1; echo \$? >> /tmp/a) & (rsync -a -e 'ssh -o BatchMode=yes' /out/ ccs-data@$web: > /tmp/b 2>&1; echo \$? >> /tmp/b) & wait"
if [[ $(on backend 'tail -n 1 /tmp/a; tail -n 1 /tmp/b') == $'0\n0' && $(live) == "$v" ]]; then ok "two pushes at once both go through, one after the other"; else on backend 'cat /tmp/a /tmp/b'; fail "two pushes at once"; fi

v=$((v + 1)); site "$v" "$(addr 2)"
if push > /dev/null && [[ $(live) == "$v" ]]; then ok "the next good push goes live again"; else fail "recovery"; fi
last=$v

for missing in "design/test:design release" "markdown.awk:markdown.awk"; do
    f=${missing%%:*}
    on web "mv /etc/ccs-gate/$f /tmp/moved"
    v=$((v + 1)); site "$v" "$(addr 2)"
    if ! push > /dev/null && [[ $(live) == "$last" ]] && on web "grep -q 'refused the push: it has no /etc/ccs-gate/' /var/log/ccs-gate.log"; then
        ok "no ${missing#*:} installed: every push refused"
    else
        fail "no ${missing#*:}"
    fi
    on web "mv /tmp/moved /etc/ccs-gate/$f"
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
if ! on backend "ssh -o BatchMode=yes ccs-data@$web 'cat /etc/passwd' 2>&1" | grep -q root; then ok "the key runs nothing else"; else fail "the key ran a command"; fi
# the heartbeat: pushes are the backend's; the web server's timer alerts when none arrive
hb() { on web 'su -s /bin/bash ccs-data -c "/usr/local/bin/ccs-receive --heartbeat"'; }
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
for _ in $(seq 100); do on web 'pgrep -f ccs-receive > /dev/null' || break; sleep 0.2; done
if (($(bot | grep -c . || true) > alerts)); then ok "a backend that hangs up mid-check: the gate still alerts"; else on web 'tail -n 3 /var/log/ccs-gate.log'; fail "a backend that hangs up mid-check: no alert from the gate"; fi

exit "$status"

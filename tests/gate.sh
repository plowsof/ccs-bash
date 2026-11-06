#!/usr/bin/env bash
# The web server's gate (contrib/ccs-receive, docs/two-machines.md): the gate's image as the web
# server (GATE_IMAGE: its own ccs-receive, ccs-gate-build and ccs-check, its sshd as compose.yml
# starts it, its users from its init), set up as documented with the design's real release
# (ccs-front-hugo's zip, checked by its sha256) and a proposals repository merged as GitLab merges;
# and a backend pushing site-data.json. A good push builds the site and it goes live; a
# site-data.json that fails, a proposal's text with an address that is neither the wallet's nor
# allowed, a list that isn't the pinned one, a push of anything else, leaves the live site as it
# was and says why. Needs docker, jq and network (the design's zip, once: GATE_CACHE keeps it).
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
img=${GATE_IMAGE:?GATE_IMAGE: the gate image to test (container/build.sh ccs-gate gate.Dockerfile)}
name=ccs-gate-test
net=172.30.98
web=$net.2 backend=$net.3
files=$(mktemp -d)
cache=${GATE_CACHE:-$HOME/.cache/ccs-gate-test}
design_v=v0.1.29 design_sha=3c1ed150a2198536d441666e38ec5c1a710df1e09f00b619a6a5e6f4083793df

cleanup() {
    docker rm -f "$name-web" "$name-backend" > /dev/null 2>&1 || true
    docker network rm "$name" > /dev/null 2>&1 || true
    rm -rf "$files"
}
trap cleanup EXIT
cleanup; files=$(mktemp -d)

# the design's release zip, as the web server installs it (design/vX.Y.Z/)
zip=$cache/ccs-front-hugo-$design_v.zip
mkdir -p "$cache"
if ! sha256sum -c --status <<<"$design_sha  $zip" 2> /dev/null; then
    curl -fsSL -o "$zip.part" "https://github.com/plowsof/ccs-front-hugo/releases/download/$design_v/ccs-front-hugo-$design_v.zip" && mv "$zip.part" "$zip"
fi
sha256sum -c --status <<<"$design_sha  $zip" || { echo "$zip: sha256 is not $design_sha" >&2; exit 2; }
mkdir "$files/design" && (cd "$files/design" && unzip -q "$zip")

# The backend: Debian 12, with ssh, qrencode (the list's QR codes, as make-qr.sh makes them) and
# python3 (the test's own helpers: hostile tars, the IRC bot; the gate's image has no Python)
docker buildx build -q --load -t "$name" - > /dev/null <<IMG
FROM debian@sha256:7ff6ba31527b9e336162fa061746c366c4b2032f4d2cff2078bea43f78efe3f8
RUN apt-get update -q && apt-get install -y -q --no-install-recommends openssh-client python3 qrencode \
    && rm -rf /var/lib/apt/lists/*
IMG
docker network create --subnet "$net.0/24" "$name" > /dev/null
docker run -d --name "$name-web" --network "$name" --ip "$web" --tmpfs /etc/ccs-ssh:mode=755 --entrypoint sleep "$img" infinity > /dev/null
docker exec -e CCS_DATA_UID=997:997 -e CCS_BACKUP_UID=998:998 "$name-web" /usr/local/bin/ccs-web-init > /dev/null
# (ccs-data by its id for docker exec: the image's passwd is a link Docker doesn't follow)
keys=/etc/ccs-ssh/authorized_keys hostkey=/etc/ccs-ssh/keys/ssh_host_ed25519_key.pub data=997:997
docker run -d --name "$name-backend" --network "$name" --ip "$backend" "$name" sleep infinity > /dev/null
on() { local h=$1; shift; docker exec "$name-$h" bash -c "$@"; }

# a wallet of four subaddresses (95 base58 characters, no checksum: the scan reads them as none,
# and every page's box is the list's by construction); the General Fund, the design's footer's,
# allowed; and two real addresses (by their checksum) the scan finds: a testnet one and the
# General Fund
addr() { printf '%s%094d' "${2:-9}" "$1" | tr 0 z; }
list=$(for i in 0 1 2 3; do echo "$i $(addr "$i")"; done)
fund=$(grep -rhoE '[48][1-9A-HJ-NP-Za-km-z]{94}' "$files/design" | sort | uniq -c | sort -rn | awk 'NR == 1 { print $2 }')
[[ $fund ]] || { echo "no General Fund address in the design" >&2; exit 2; }
fake=9uH2Z776LeJ4gku967Y3o8VrBueTqSoQhDXVftRkU2Jt81du8DDNV4eAFmPaojQV4mhrgDBvzUfRX7EoHp245dNf9wimfPf

on backend 'mkdir -p ~/.ssh && ssh-keygen -q -t ed25519 -N "" -f ~/.ssh/id_ed25519'
# the list's QR codes and their sums, made on the backend (the web server has no qrencode)
on backend "mkdir -p /qr && cd /qr && printf '%s\n' '$list' | while read -r _ a; do qrencode -s 10 -o \$a.png monero:\$a; done \
    && printf '%s\n' '$list' | while read -r _ a; do sha256sum \$a.png; done > /qr.sha256"
docker cp "$name-backend:/qr" "$files/qr" && docker cp "$name-backend:/qr.sha256" "$files/qr.sha256"
docker cp "$files/qr" "$name-web:/tmp/qr" && docker cp "$files/qr.sha256" "$name-web:/tmp/qr.sha256"
docker cp "$files/design" "$name-web:/tmp/design"
key=$(on backend 'cat ~/.ssh/id_ed25519.pub')
docker cp "$here/../contrib/ccs-push" "$name-backend:/ccs-push"
# hostile.py KIND: a tar no backend's push makes, to stdout (python's tarfile writes what it's told)
cat > "$files/hostile.py" <<'PY'
import io, sys, tarfile
out = tarfile.open(fileobj=sys.stdout.buffer, mode="w|", format=tarfile.GNU_FORMAT)
def add(name, body=b"x", typ=tarfile.REGTYPE, link=""):
    t = tarfile.TarInfo(name); t.type = typ; t.linkname = link; t.mode = 0o644
    if typ == tarfile.REGTYPE: t.size = len(body); out.addfile(t, io.BytesIO(body))
    else: out.addfile(t)
k = sys.argv[1]
if k == "symlink": add("site-data.json", typ=tarfile.SYMTYPE, link="/etc/passwd")
if k == "hardlink": add("a.txt"); add("site-data.json", typ=tarfile.LNKTYPE, link="a.txt")
if k == "device": add("site-data.json", typ=tarfile.CHRTYPE)
if k == "dotdot": add("../../../tmp/escaped")
if k == "absolute": add("/tmp/escaped")
if k == "twice": add("site-data.json", b"{}"); add("./site-data.json", b"{}")
if k == "address": add("pay/" + sys.argv[2] + "/../x.json")
if k == "page": add("site-data.json", b"{}"); add("index.html", b"<p>Donate here</p>")
if k == "many": [add("f%05d.txt" % i) for i in range(20000)]
out.close()
PY
docker cp "$files/hostile.py" "$name-backend:/hostile.py"

# the proposals repository, as GitLab merges: each proposal its branch, merged with "See merge
# request monero-project/ccs-proposals!N" (its link on the site, MERGE_REQUESTS'); p Funding
# Required, w Work in Progress, d Completed, with an image
# propose NAME LAYOUT TITLE MR [TEXT]
cat > "$files/repo.sh" <<'SH'
set -e
g() { git -c safe.directory='*' -c user.name=t -c user.email=t@t "$@"; }
propose() {
    cd /srv/proposals
    g checkout -q -b "$1" master
    printf '%s\n' --- "layout: $2" "title: $3" 'author: someone' 'date: October 22, 2026' 'amount: 10' \
        'milestones:' '  - name: One' '    funds: 10 XMR' --- "${5:-A plain proposal, in 2 parts.}" > "$1.md"
    g add -A && g commit -q -m "$3"
    g checkout -q master && g merge -q --no-ff "$1" -m "Merge branch '$1' into 'master'" -m "$3" -m "See merge request monero-project/ccs-proposals!$4"
}
# edit NAME TEXT: a merge that changes NAME's text (its merge request is still the first one's)
edit() {
    cd /srv/proposals
    g checkout -q -b "edit-$1-$RANDOM" master
    sed -i '$d' "$1.md" && printf '%s\n' "$2" >> "$1.md"
    g commit -q -am "edit $1"
    b=$(g branch --show-current); g checkout -q master && g merge -q --no-ff "$b" -m "Merge branch '$b' into 'master'" -m "See merge request monero-project/ccs-proposals!99"
}
gone() { cd /srv/proposals && for n in "$@"; do g rm -q "$n.md"; done && g commit -q -m "taken out: $*"; }
# front NAME [LINE]: a merge that adds LINE to NAME's front matter (none: takes its gitlab_url out)
front() {
    cd /srv/proposals
    g checkout -q -b "front-$1-$RANDOM" master
    if [[ ${2:-} ]]; then sed -i "1a $2" "$1.md"; else sed -i '/^gitlab_url:/d' "$1.md"; fi
    g commit -q -am "front $1"
    b=$(g branch --show-current); g checkout -q master && g merge -q --no-ff "$b" -m "Merge branch '$b' into 'master'" -m "See merge request monero-project/ccs-proposals!98"
}
"$@"
chown -R ccs-data /srv/proposals 2> /dev/null || chown -R 997:997 /srv/proposals
SH
docker cp "$files/repo.sh" "$name-web:/tmp/repo.sh"
repo() { on web "bash /tmp/repo.sh $(printf '%q ' "$@")"; }
on web "
    install -d -o ${data%:*} -g ${data#*:} -m 755 /var/lib/ccs-data /var/lib/ccs-staging /var/lib/ccs-gate
    install -d -m 755 /etc/ccs-gate /etc/ccs-gate/design
    install -o ${data%:*} -g ${data#*:} -m 644 /dev/null /var/log/ccs-gate.log
    printf 'ALERT_URL=http://$backend:9999/simple\nSITE_URL=https://ccs.test\n' > /etc/ccs-gate/alert.conf
    printf '%s\n' '$list' > /etc/ccs-gate/subaddresses.txt
    cp /tmp/qr.sha256 /etc/ccs-gate/subaddresses.txt.qr.sha256 && cp -r /tmp/qr /etc/ccs-gate/subaddresses.txt.qr
    printf 'sha256 %s\nkey %040d\nqr %s\n' \"\$(sha256sum < /etc/ccs-gate/subaddresses.txt | cut -d' ' -f1)\" 0 \"\$(sha256sum < /etc/ccs-gate/subaddresses.txt.qr.sha256 | cut -d' ' -f1)\" > /etc/ccs-gate/subaddresses.txt.pin
    printf '%s  # the General Fund\n' '$fund' > /etc/ccs-gate/allowed
    echo sig > /etc/ccs-gate/subaddresses.txt.asc && echo key > /etc/ccs-gate/subaddresses.txt.key.asc
    printf '%064d\nsource https://repo.test/viewkey\nsource-text published here\n' 7 > /etc/ccs-gate/subaddresses.txt.viewkey
    cp -r /tmp/design /etc/ccs-gate/design/$design_v
    mkdir -p /srv/proposals && cd /srv/proposals && git -c safe.directory='*' init -q -b master \
        && git -c safe.directory='*' -c user.name=t -c user.email=t@t commit -q --allow-empty -m start
    printf 'PROPOSALS_GIT=file:///srv/proposals\nLINK_HOSTS=repo.test/monero-project/ccs-proposals\nMERGE_REQUESTS=https://repo.test\n' > /etc/ccs-gate/proposals.conf
    chmod -R a+rX /etc/ccs-gate
    install -d -m 755 $keys
    echo 'from=\"$backend\",command=\"/usr/local/bin/ccs-receive\",restrict $key' > $keys/ccs-data
    chmod 644 $keys/ccs-data
    /usr/sbin/sshd -p 22 -o AllowUsers=ccs-data -o ForceCommand=/usr/local/bin/ccs-receive
"
repo propose p fr 'A proposal' 5
repo propose w wip 'Work going on' 6
repo propose d cp 'Done and dusted' 7
on backend "echo '$web $(on web "cat $hostkey")' > ~/.ssh/known_hosts"
# a fake bot, keeping what it is sent (the gate's alerts)
docker exec -d "$name-backend" python3 -c '
import http.server
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        open("/tmp/bot.txt", "ab").write(self.rfile.read(n) + b"\n")
        self.send_response(200); self.end_headers()
    def log_message(self, *a): pass
http.server.HTTPServer(("0.0.0.0", 9999), H).serve_forever()'
bot() { on backend 'cat /tmp/bot.txt 2> /dev/null || true' | tr -d '\003' | sed 's/12CCS-watch/CCS-watch/; s/04\([0-9A-Za-z]\{6\}…\)/\1/g'; }

status=0
ok() { echo "ok   $1"; }
fail() { echo "FAIL $1"; status=1; }
# data RAISED [P_INDEX [W_INDEX]]: site-data.json as ccs-bash writes it (every proposal's state
# and funds), p's funds RAISED; the proposals beside p and w: $other, each fully funded
other=d
data() {
    local r=$1 pi=${2:-1} wi=${3:-2} o
    printf '{"state": {'
    for o in $other; do printf '"%s.md": {"subaddr_index": null, "funding_required_date": null, "funded_date": null},\n  ' "$o"; done
    printf '"p.md": {"subaddr_index": %s, "funding_required_date": "2026-10-25T13:00:00Z", "funded_date": null},\n' "$pi"
    printf '  "w.md": {"subaddr_index": %s, "funding_required_date": null, "funded_date": "2026-10-26T13:00:00Z"}},\n' "$wi"
    printf ' "funds": {'
    for o in $other; do printf '"%s.md": {"amount": "10.0000", "raised": "10.0000", "pending": 0, "count": 2, "percentage": 100, "needed": "0.0000"},\n  ' "$o"; done
    printf '"p.md": {"amount": "10.0000", "raised": "%s", "pending": 0, "count": 1, "percentage": 10, "needed": "9.0000"},\n' "$r"
    printf '  "w.md": {"amount": "10.0000", "raised": "10.0000", "pending": 0, "count": 2, "percentage": 100, "needed": "0.0000"}},\n'
    printf ' "ideas": [{"name": "An idea", "gitlab-url": "https://repo.test/monero-project/ccs-proposals/-/merge_requests/9", "author": "erin", "date": "October 1, 2026", "upvotes": 1, "downvotes": 0}]}\n'
}
# put FILE: stdin as the backend's /out/FILE
put() { docker exec -i "$name-backend" sh -c "mkdir -p \"\$(dirname '/out/$1')\" && cat > '/out/$1'"; }
# push: as the backend pushes (contrib/ccs-push): what changed, a tar over ssh
push() { on backend "/ccs-push /out/site-data.json /state -T -o BatchMode=yes -o StrictHostKeyChecking=yes ccs-data@$web 2>&1"; }
# hostile KIND: hostile.py's tar sent as a push; its exit
hostile() { on backend "python3 /hostile.py $1 ${2:-} | ssh -T -o BatchMode=yes ccs-data@$web receive > /dev/null 2>&1"; }
livefile() { on web "cat '/var/lib/ccs-data/$1' 2> /dev/null || true"; }
livepage() { livefile proposals/p.html; }
built() { on web "grep -c 'built the site from site-data.json' /var/log/ccs-gate.log || true"; }
logtail() { on web "tail -n ${1:-4} /var/log/ccs-gate.log"; }
# a version of the site: p's raised total
raised() { livefile projects.json | jq -r '.[] | select(.filename == "p.md") | .raised_amount' 2> /dev/null || true; }

on backend 'mkdir -p /out'
data 1.0000 | put site-data.json
if out=$(push) && [[ $(livepage) == *"$(addr 1)"* && $(livefile proposals/w.html) == *"Work going on"* ]] \
    && on web "cmp -s /var/lib/ccs-data/qr/$(addr 1).png /etc/ccs-gate/subaddresses.txt.qr/$(addr 1).png"; then
    ok "a push of site-data.json: the site built here and live (p's box its index's address, its QR code the list's file)"
else echo "$out"; logtail 8; fail "a good push"; fi
if [[ $(livepage) == *'href="https://repo.test/monero-project/ccs-proposals/-/merge_requests/5"'* \
    && $(livefile proposals/w.html) == *'merge_requests/6"'* ]]; then
    ok "each proposal links to the merge request that added it, read from the repository's merge commits"
else livepage | grep -o 'href="[^"]*merge[^"]*"' || true; fail "the merge request links"; fi
if on web "grep -qx 'p.md $(addr 1)' /var/lib/ccs-gate/pins && grep -qx 'w.md $(addr 2)' /var/lib/ccs-gate/pins"; then
    ok "review 12 (M-2): each proposal's address pinned by the gate itself (/var/lib/ccs-gate/pins), from when it went live"
else on web 'cat /var/lib/ccs-gate/pins' || true; fail "the pins"; fi
if [[ $(on web "stat -c %a /var/lib/ccs-data/index.html /var/lib/ccs-data/proposals" | tr '\n' ' ') == "644 755 " ]]; then
    ok "the site's files 644, its folders 755"
else on web "ls -la /var/lib/ccs-data"; fail "file modes"; fi
# nothing new: nothing built (ccs-push sends nothing; the push is the heartbeat)
n=$(built); push > /dev/null || true
if [[ $(built) == "$n" ]]; then ok "the same site-data.json again: nothing built"; else logtail; fail "the same data built again"; fi
data 2.0000 | put site-data.json
if push > /dev/null && [[ $(raised) == 2 && $(built) == $((n + 1)) ]]; then ok "a donation (site-data.json changed): the site built again, live"; else logtail; fail "a new site-data.json"; fi
# a merge that edits a proposal: its link stays the merge request that added it
repo edit p 'A plain proposal, in 3 parts.'
if push > /dev/null && [[ $(livepage) == *"in 3 parts."* && $(livepage) == *'merge_requests/5"'* ]]; then
    ok "a proposal edited (a new commit: built again), its link still its own merge request"
else logtail; fail "an edited proposal"; fi
# review 12's L-3: a proposal's own gitlab_url (front matter) doesn't override its merge request,
# and links nowhere but the repository's merge requests
repo front p 'gitlab_url: https://evil.test/donate'
if push > /dev/null && [[ $(livepage) == *'merge_requests/5"'* && $(livepage) != *evil.test* && $(livefile projects.json) != *evil.test* ]]; then
    ok "review 12 (L-3): a gitlab_url in a proposal's front matter: its link is still its merge request"
else livepage | grep -o 'href="[^"]*"' | grep -v '\.\./' || true; fail "a front matter gitlab_url"; fi
repo front p
# one of the repository's own merge requests: the proposer's correction wins (a file added twice:
# rehrar-defcon-reimburse-2019.md, !67 then !69)
repo front p 'gitlab_url: https://repo.test/monero-project/ccs-proposals/-/merge_requests/77'
if push > /dev/null && [[ $(livepage) == *'merge_requests/77"'* ]]; then
    ok "a gitlab_url in the front matter that is the repository's own merge request: its link"
else livepage | grep -o 'href="[^"]*merge[^"]*"' || true; fail "a front matter merge request"; fi
repo front p

# the push is site-data.json alone: a page, or anything else, refuses all of it
rc=0; hostile page || rc=$?
if ((rc == 1)) && [[ $(livefile index.html) != *"Donate here"* ]] && on web "grep -q 'other files than site-data.json (./index.html)' /var/log/ccs-gate.log" \
    && bot | grep -qF "the web server refuses every push: a push with other files than site-data.json"; then
    ok "a push with a page in it: refused whole, IRC told"
else echo "exit $rc"; logtail 2; fail "a push with a page"; fi

# site-data.json that fails (ccs-check data): held back, the live site as it was, IRC told
before=$(raised)
held_data() {   # held_data WHY GREP < site-data.json
    put site-data.json
    rc=0; push > /dev/null || rc=$?
    if ((rc == 1)) && [[ $(raised) == "$before" ]] && on web "grep -q 'site-data.json held back (.*$2' /var/log/ccs-gate.log"; then ok "held back: $1"
    else echo "exit $rc"; logtail 3; fail "$1"; fi
}
data 3.0000 7 | held_data "an index the signed list hasn't" "index the signed list hasn"
data 3.0000 0 | held_data "index 0, the wallet's main address" "main address"
data 3.0000 3 | held_data "another index than the live site has for p" "another subaddress than the live site"
data 3.0000 2 3 | held_data "w's index given to p" "another subaddress than the live site"
data 3.0000 | sed 's/"pending": 0,/"pending": 0, "address": "x",/' | held_data "a key ccs-bash doesn't write" "isn.t as ccs-bash writes it"
data 3.0000 | sed 's#"name": "An idea"#"name": "<b>An</b> idea"#' | held_data "markup in an idea's name" "plain text"
data 3.0000 | sed "s#\"name\": \"An idea\"#\"name\": \"Send to $fake\"#" | held_data "an address-long run in an idea's name" "plain text"
data 3.0000 | sed 's#repo.test/monero-project/ccs-proposals/-/merge_requests/9#evil.test/x/-/merge_requests/9#' | held_data "an idea's link to another forge" "isn.t a merge request"
data 3.0000 | sed 's/"d.md"/"x.md"/' | held_data "a proposal the repository hasn't" "no proposal in the proposals repository"
# review 12's H-1: a key Go's decoder takes for another, or one twice (jq, which builds the site,
# reads only the exact key): one site-data.json for the check, another for the build
data 3.0000 0 | sed 's/"subaddr_index": 0,/"subaddr_index": 0, "Subaddr_Index": 1,/' | held_data "review 12 (H-1): Subaddr_Index beside subaddr_index" "the key .Subaddr_Index"
data 3.0000 | sed 's/^{"state": {/{"STATE": {}, "state": {/' | held_data "review 12 (H-1): STATE beside state" "the key .STATE"
data 3.0000 | sed 's/"name": "An idea"/"name": "An idea", "name": "x"/' | held_data "review 12 (H-1): a key twice" "twice"
# review 12's M-1: an address in an idea's name in groups, one letter Cyrillic: as the gate's scan
# reads it, an address
grouped=$(for ((i = 0; i < 95; i += 4)); do printf '%s ' "${fake:i:4}"; done)
data 3.0000 | sed "s#\"name\": \"An idea\"#\"name\": \"Send to ${grouped/a/а}\"#" | held_data "review 12 (M-1): an address in groups in an idea's name, a letter Cyrillic" "an address in its name"
# review 12's M-2: a proposal the live site has given an address (the pins) keeps it: no index
# (which would hide it for a push, then let any other be given) is held back too
data 3.0000 null | held_data "review 12 (M-2): p's index null, where the live site gave it one" "no subaddress, where the live site has given it one"
if bot | grep -qF "the web server held back the backend's site-data.json"; then ok "... and IRC is told"; else bot | tail -n 2; fail "no alert for site-data.json"; fi
data 3.0000 | put site-data.json
if push > /dev/null && [[ $(raised) == 3 ]]; then ok "the next good site-data.json goes live"; else logtail; fail "after a held site-data.json"; fi

# a new Funding Required proposal without an index yet: kept off the site (no box without an
# address)
repo propose n fr 'A new one' 8
if push > /dev/null && on web '! test -e /var/lib/ccs-data/proposals/n.html' && [[ $(livepage) == *"$(addr 1)"* ]]; then
    ok "a new Funding Required proposal without an index: kept off the site"
else logtail; fail "a proposal without an index"; fi
repo gone n

# an address in a proposal's own text (merged into the repository): that page off the site, IRC
# told, the rest live; the General Fund's (allowed) goes live
repo edit w "Pay $fake here."
data 4.0000 | put site-data.json
if push > /dev/null && on web '! test -e /var/lib/ccs-data/proposals/w.html' && [[ $(raised) == 4 ]] \
    && on web "grep -q 'proposals/w.html: $fake' /var/log/ccs-gate.log" \
    && bot | grep -qF "the web server took a page off the site: donation address ${fake:0:6}…${fake: -4} is not in the signed list @ https://ccs.test/proposals/w.html"; then
    ok "an address in a proposal's text that isn't the wallet's: that page taken off the site, IRC told, the rest live"
else logtail 5; bot | tail -n 2; fail "an address in a proposal's text"; fi
repo edit w "Or give to the General Fund, $fund."
if push > /dev/null && [[ $(livefile proposals/w.html) == *"$fund"* ]]; then ok "an allowed address (the General Fund) in a proposal's text goes live"; else logtail; fail "an allowed address"; fi
# split, in groups, by markup the proposal's markdown makes: found all the same
repo edit w "Send to $grouped"
if push > /dev/null && on web '! test -e /var/lib/ccs-data/proposals/w.html'; then ok "an address in groups of four in a proposal's text: found, the page off the site"; else logtail; fail "an address in groups"; fi
repo edit w "Send to ${fake:0:40}**${fake:40:10}**${fake:50}"
if push > /dev/null && on web '! test -e /var/lib/ccs-data/proposals/w.html'; then ok "an address split by markup (bold) in a proposal's text: found"; else logtail; fail "an address split by markup"; fi
# review 12's M-1: written backwards after a bidi override (which would show it the right way
# round): the override dropped from the text (ccs-check nobidi), so the page shows it as written,
# backwards, no address; with a letter drawn as an address's (a Cyrillic а): found, the page off
backwards=$(rev <<<"$grouped")
for c in "written backwards after U+202E (as an entity)|&#x202E;$backwards&#x202C;" "written backwards after a raw U+202E|$(printf '\xe2\x80\xae')$backwards"; do
    IFS='|' read -r what text <<<"$c"
    repo edit w "Send to $text"
    if push > /dev/null && [[ $(livefile proposals/w.html) == *"Send to ${backwards% }"* ]] \
        && ! livefile proposals/w.html | grep -qE "$(printf '\xe2\x80[\xaa-\xae]')|&#x202[a-eA-E];"; then
        ok "review 12 (M-1): an address $what: the override dropped, the page live as written"
    else logtail; livefile proposals/w.html | grep -o 'Send to.\{0,40\}' || true; fail "an address $what"; fi
done
repo edit w "Send to ${grouped/a/а}"
if push > /dev/null && on web '! test -e /var/lib/ccs-data/proposals/w.html' && on web "grep -qF 'proposals/w.html: $fake' /var/log/ccs-gate.log"; then
    ok "review 12 (M-1): an address in groups, a letter Cyrillic, in a proposal's text: the page off the site"
else logtail; fail "an address in groups, a letter Cyrillic"; fi
repo edit w 'Back to work.'
if push > /dev/null && [[ $(livefile proposals/w.html) == *"Back to work."* ]]; then ok "the text mended: the page back"; else logtail; fail "a mended page"; fi

# a proposal taken out of the repository: its page goes; more than 3 pages at once: none of the
# new site goes live, IRC told
repo gone d
other=''
if push > /dev/null && on web '! test -e /var/lib/ccs-data/proposals/d.html' \
    && bot | grep -qF 'the web server took a page off the site: its proposal is no longer in the repository, or the backend hides it @ https://ccs.test/proposals/d.html'; then
    ok "a proposal taken out of the repository: its page goes, IRC told (review 12's M-2)"
else logtail; bot | tail -n 2; fail "a removed proposal"; fi
for n in 1 2 3 4; do repo propose "x$n" wip "Extra $n" $((20 + n)); done
other='x1 x2 x3 x4'
data 4.0000 | put site-data.json
push > /dev/null || true
[[ $(livefile proposals/x4.html) == *"Extra 4"* ]] || { logtail; fail "four more proposals"; }
repo gone x1 x2 x3 x4
other=''
data 5.0000 | put site-data.json
rc=0; push > /dev/null || rc=$?
if ((rc == 1)) && on web 'test -e /var/lib/ccs-data/proposals/x1.html && test -e /var/lib/ccs-data/proposals/x4.html' && [[ $(raised) == 4 ]] \
    && bot | grep -qE 'the web server would take [0-9]+ pages off the site within a day'; then
    ok "four proposal pages leaving at once: none of the new site live, IRC told"
else echo "exit $rc"; logtail 4; fail "many removed at once"; fi
# a person lets them go: allow-remove, for one build
on web "touch /var/lib/ccs-gate/allow-remove && chown $data /var/lib/ccs-gate/allow-remove"
if push > /dev/null && on web '! test -e /var/lib/ccs-data/proposals/x1.html && ! test -e /var/lib/ccs-gate/allow-remove' && [[ $(raised) == 5 ]]; then
    ok "allow-remove: the four go, the new site live, the file used up"
else logtail 3; fail "allow-remove"; fi
# review 12's M-2: one at a time, a push each, counts as at once: the fourth within a day held
for n in 1 2 3 4; do repo propose "y$n" wip "Extra $n" $((30 + n)); done
push > /dev/null || true
for n in 1 2 3; do repo gone "y$n"; push > /dev/null || true; done
repo gone y4
rc=0; push > /dev/null || rc=$?
if ((rc == 1)) && on web '! test -e /var/lib/ccs-data/proposals/y3.html && test -e /var/lib/ccs-data/proposals/y4.html'; then
    ok "review 12 (M-2): pages leaving one a push: the fourth within a day held, as four at once"
else echo "exit $rc"; logtail 4; fail "pages leaving one at a time"; fi
on web "touch /var/lib/ccs-gate/allow-remove && chown $data /var/lib/ccs-gate/allow-remove"
push > /dev/null || true

# the QR codes: only the list's own files, by their sums (ccs-front-bash checks them as it
# builds; ccs-check gate again after)
on web "cp /etc/ccs-gate/subaddresses.txt.qr/$(addr 1).png /tmp/qr1 && cp /etc/ccs-gate/subaddresses.txt.qr/$(addr 2).png /etc/ccs-gate/subaddresses.txt.qr/$(addr 1).png"
rc=0; push > /dev/null || rc=$?
if ((rc == 1)) && on web "cmp -s /var/lib/ccs-data/qr/$(addr 1).png /tmp/qr1" && on web "grep -q 'subaddresses.txt.qr/$(addr 1).png is not its sum' /var/log/ccs-gate.log"; then
    ok "a QR code installed that isn't the list's (another's): not built, the live one stays"
else echo "exit $rc"; logtail 3; fail "a wrong QR code"; fi
on web "cp /tmp/qr1 /etc/ccs-gate/subaddresses.txt.qr/$(addr 1).png"

# what it's built from changes, or a day passes: built again
on web 'printf "# nothing\n" >> /etc/ccs-gate/allowed'
n=$(built); push > /dev/null || true
if [[ $(built) == $((n + 1)) ]]; then ok "allowed changed: built again"; else logtail; fail "allowed changed"; fi
on web 'touch -d "@$(($(date +%s) - 25 * 3600))" /var/lib/ccs-gate/built-with'
n=$(built); push > /dev/null || true
if [[ $(built) == $((n + 1)) ]]; then ok "a day after the last build: built again"; else logtail; fail "the daily build"; fi

# the repository can't be fetched: built from the last fetch, the site goes on; for FORGE_HOURS
# (default 6) since the last good fetch, one alert an hour; fetched again, it says so
on web "sed -i 's#=file:///srv/proposals#=file:///nowhere#' /etc/ccs-gate/proposals.conf"
data 6.0000 | put site-data.json
if push > /dev/null && [[ $(raised) == 6 ]] && on web "grep -q 'building from the last fetch' /var/log/ccs-gate.log" \
    && ! bot | grep -q 'fetch the proposals repository'; then ok "the proposals repository can't be fetched: built from the last fetch (no alert yet)"; else logtail; fail "the repository down"; fi
on web 'touch -d "@$(($(date +%s) - 7 * 3600))" /var/lib/ccs-gate/fetch-ok'   # (seconds: busybox's touch reads no "-7 hours")
data 7.0000 | put site-data.json; push > /dev/null || true
data 8.0000 | put site-data.json; push > /dev/null || true
if [[ $(bot | grep -c "the web server can't fetch the proposals repository since" || true) == 1 ]]; then ok "the repository down for 7 hours: one alert, not one a push"; else bot; fail "the repository down for long"; fi
on web "sed -i 's#=file:///nowhere#=file:///srv/proposals#' /etc/ccs-gate/proposals.conf"
data 9.0000 | put site-data.json; push > /dev/null || true
if [[ $(bot | grep -c 'the web server fetches the proposals repository again @ https://ccs.test' || true) == 1 ]]; then ok "the repository fetched again: says so, once"; else bot; fail "the repository back"; fi

# a build that fails (here the design's proposal part missing): the live site as it was, IRC told
on web "mv /etc/ccs-gate/design/$design_v/parts/proposal-wip.html /tmp/"
data 10.0000 | put site-data.json
rc=0; push > /dev/null || rc=$?
if ((rc == 1)) && [[ $(raised) == 9 ]] && bot | grep -qF 'the web server could not build the site from site-data.json'; then
    ok "a build that fails: the live site as it was, IRC told"
else echo "exit $rc"; logtail; fail "a failed build"; fi
on web "mv /tmp/proposal-wip.html /etc/ccs-gate/design/$design_v/parts/"
push > /dev/null || true
last=$(raised)

# what the gate needs, missing or not as pinned: every push refused, the live site as it was
refused() {   # refused WHY LOG
    rc=0; out=$(push) || rc=$?
    if ((rc == 1)) && [[ $(raised) == "$last" ]] && on web "grep -q 'refused the push: $2' /var/log/ccs-gate.log"; then ok "$1: every push refused"
    else echo "exit $rc: $out"; logtail 3; fail "$1"; fi
}
n=11
for missing in "design/$design_v|no design release|it has no /etc/ccs-gate/design/" "subaddresses.txt.qr|no QR codes installed|it has no /etc/ccs-gate/subaddresses.txt.qr/"; do
    IFS='|' read -r f what log <<<"$missing"
    on web "mv /etc/ccs-gate/$f /tmp/moved"
    data "$n.0000" | put site-data.json; n=$((n + 1))
    refused "$what" "$log"
    on web "mv /tmp/moved /etc/ccs-gate/$f"
done
on web "mv /etc/ccs-gate/design/$design_v /etc/ccs-gate/design/$design_v-rc1"
data "$n.0000" | put site-data.json; n=$((n + 1))
refused "only a build of no release (vX.Y.Z-rc1)" "it has no /etc/ccs-gate/design/"
on web "mv /etc/ccs-gate/design/$design_v-rc1 /etc/ccs-gate/design/$design_v"
on web "cp /etc/ccs-gate/subaddresses.txt /etc/ccs-gate/subaddresses.txt.pin /etc/ccs-gate/subaddresses.txt.qr.sha256 /tmp/ && echo '4 $(addr 4)' >> /etc/ccs-gate/subaddresses.txt"
refused "a list that isn't the pinned one" "/etc/ccs-gate/subaddresses.txt is not the list"
if bot | grep -qF "[CCS-watch] the web server refuses every push: its signed list isn't the one its .pin names"; then ok "... and IRC is told"; else fail "no alert for the list"; fi
on web "cp /tmp/subaddresses.txt /etc/ccs-gate/ && echo >> /etc/ccs-gate/subaddresses.txt.qr.sha256"
refused "QR codes' sums that aren't the pinned ones" ".*subaddresses.txt.qr.sha256 is not the QR codes. sums"
on web "cp /tmp/subaddresses.txt.qr.sha256 /etc/ccs-gate/ && : > /etc/ccs-gate/subaddresses.txt \
    && sed -i \"s/^sha256 .*/sha256 \$(sha256sum < /etc/ccs-gate/subaddresses.txt | cut -d' ' -f1)/\" /etc/ccs-gate/subaddresses.txt.pin"
refused "review 11 (I-1): an empty list, pinned" ".*subaddresses.txt has no addresses"
on web 'cp /tmp/subaddresses.txt /tmp/subaddresses.txt.pin /etc/ccs-gate/'

# a tar no backend makes (a link, a device, a path out, a name twice): refused whole, nothing
# live changed, nothing outside, IRC told
for k in symlink hardlink device dotdot absolute twice; do
    before=$(on web 'find /var/lib/ccs-data -type f | sort | xargs sha256sum | sha256sum')
    rc=0; hostile "$k" || rc=$?
    if ((rc == 1)) && [[ $(on web 'find /var/lib/ccs-data -type f | sort | xargs sha256sum | sha256sum') == "$before" ]] \
        && on web '! test -e /tmp/escaped && ! test -e /var/lib/escaped && ! find /var/lib/ccs-data /var/lib/ccs-staging -type l | grep -q .'; then
        ok "refused whole: a push with a $k entry"
    else echo "exit $rc"; logtail 2; fail "a push with a $k entry"; fi
done
if bot | grep -qF "the web server refused a push it could not take"; then ok "... and IRC is told"; else bot | tail -n 3; fail "no alert for a refused tar"; fi
# review 10's L-1: IRC is told why, but never a whole address the backend chose (a name quoting one)
on web 'rm -f /var/lib/ccs-gate/alert-receive'
hostile address "$fake" || true
if bot | grep -qF "${fake:0:6}…${fake: -4}" && ! bot | grep -qF "$fake"; then ok "review 10 (L-1): a refused push's reason in IRC with its address shortened"; else bot | tail -n 2; fail "review 10 (L-1): a whole address in an alert"; fi
if [[ $(on backend "printf 'not a tar' | ssh -T -o BatchMode=yes ccs-data@$web receive > /dev/null 2>&1; echo \$?") == 1 ]]; then ok "refused: a push that isn't a tar"; else fail "a push that isn't a tar"; fi
# the key still runs nothing but the gate
if ! grep -q root <<<"$(on backend "ssh -o BatchMode=yes ccs-data@$web 'cat /etc/passwd' 2>&1")"; then ok "the key runs nothing else"; else fail "the key ran a command"; fi

# two pushes at once: the second waits for the first (one staging folder, one at a time)
data 40.0000 | put site-data.json
on backend "(/ccs-push /out/site-data.json /state-a -T -o BatchMode=yes ccs-data@$web > /tmp/a 2>&1; echo \$? >> /tmp/a) & (/ccs-push /out/site-data.json /state-b -T -o BatchMode=yes ccs-data@$web > /tmp/b 2>&1; echo \$? >> /tmp/b) & wait"
if [[ $(on backend 'tail -n 1 /tmp/a; tail -n 1 /tmp/b') == $'0\n0' && $(raised) == 40 ]]; then ok "two pushes at once both go through, one after the other"; else on backend 'cat /tmp/a /tmp/b'; fail "two pushes at once"; fi
# a backend that hangs up while the gate builds: the gate still finishes, and alerts what it took off
repo edit w "Pay $fake here."
data 41.0000 | put site-data.json
alerts=$(bot | grep -c . || true)
on web 'rm -f /var/lib/ccs-gate/alert-addr-*'
before=$(on web 'stat -c %Y /var/lib/ccs-gate/last-push 2> /dev/null || echo 0')
on backend "/ccs-push /out/site-data.json /state -T -o BatchMode=yes ccs-data@$web > /dev/null 2>&1 &"
for _ in $(seq 100); do [[ $(on web 'stat -c %Y /var/lib/ccs-gate/last-push 2> /dev/null || echo 0') != "$before" ]] && break; sleep 0.1; done
on backend 'pkill -x ssh || true'
for _ in $(seq 300); do on web 'for p in /proc/[0-9]*/cmdline; do { tr "\0" " " < $p; } 2> /dev/null; echo; done | grep -q "[c]cs-receive"' || break; sleep 0.2; done
if (($(bot | grep -c . || true) > alerts)) && [[ $(raised) == 41 ]]; then ok "a backend that hangs up mid-build: the gate still builds, and alerts"; else logtail 3; fail "a backend that hangs up mid-build"; fi
repo edit w 'Back to work.'

# review 12's L-1: no alert.conf (optional): the gate still builds; thousands of files: refused,
# with its reason (not a silent SIGPIPE)
on web 'mv /etc/ccs-gate/alert.conf /tmp/alert.conf'
data 42.0000 | put site-data.json
if push > /dev/null && [[ $(raised) == 42 ]]; then ok "review 12 (L-1): no alert.conf: built, live"; else logtail; fail "no alert.conf"; fi
on web 'mv /tmp/alert.conf /etc/ccs-gate/alert.conf'
rc=0; hostile many || rc=$?
if ((rc == 1)) && on web "tail -n 1 /var/log/ccs-gate.log | grep -q 'other files than site-data.json (./f'"; then
    ok "review 12 (L-1): a push of 20,000 files: refused, saying why"
else echo "exit $rc"; logtail 2; fail "a push of many files"; fi

# the heartbeat: pushes are the backend's; the web server's timer alerts when none arrive
hb() { docker exec -u "$data" "$name-web" /usr/local/bin/ccs-receive --heartbeat; }
late() { bot | grep -c 'no push from the backend' || true; }
push > /dev/null || true
hb
if [[ $(late) == 0 ]]; then ok "heartbeat: a recent push, no alert"; else bot; fail "heartbeat after a push"; fi
# 1 minute, not 15: a CI machine may have been up less than 15 (then the heartbeat waits), and
# not before it has been up that long either
on web "echo HEARTBEAT_MINUTES=1 >> /etc/ccs-gate/alert.conf && touch -d @\$((\$(date +%s) - 300)) /var/lib/ccs-gate/last-push"
on web 'until (($(cut -d. -f1 /proc/uptime) >= 70)); do sleep 5; done'
hb
if [[ $(late) == 0 ]]; then ok "heartbeat: the first late check waits for a second"; else fail "heartbeat alerted on one check"; fi
hb
if bot | grep -qE '^\[CCS-watch\] no push from the backend for [5-9] minutes: is it running\? .* @ https://ccs.test$'; then
    ok "heartbeat: no push for longer than HEARTBEAT_MINUTES, two checks in a row: the web server tells IRC"
else bot; fail "heartbeat alert"; fi
hb
if [[ $(late) == 1 ]]; then ok "heartbeat: once an hour, not every check"; else bot; fail "a repeated heartbeat alert"; fi
push > /dev/null || true
hb
if bot | grep -qF '[CCS-watch] pushes from the backend arrive again @ https://ccs.test'; then ok "heartbeat: pushes arrive again, IRC is told"; else bot; fail "heartbeat recovery"; fi
on web 'rm -f /var/lib/ccs-gate/last-push /var/lib/ccs-gate/alert-heartbeat'
hb
if [[ $(late) == 1 ]]; then ok "heartbeat: before any push, nothing is known: no alert"; else fail "heartbeat without a push"; fi

exit "$status"

#!/usr/bin/env bash
# contrib/ccs-watch against a local "web server" (python3 http.server) and a fake bot that keeps
# what it is sent: every address the wallet's, no alert; a foreign address on a page, or a box
# that isn't its proposal's, an alert naming it, once an hour; the site down three times, an alert.
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
tmp=$(mktemp -d)
pids=()
trap 'kill "${pids[@]}" 2> /dev/null || true; [[ ${SHOW:-} ]] && cat "$tmp/bot.txt"; rm -rf "$tmp"' EXIT
status=0
ok() { echo "ok   $1"; }
fail() { echo "FAIL $1"; status=1; }
port() { python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }

# ccs-watch here, or with CCS_WATCH_IMAGE, the one in that image (ccs-bash's: its busybox), on the
# host's network (the test's servers on 127.0.0.1), as this user, the test's folder at its path
ccs_watch() {
    if [[ ${CCS_WATCH_IMAGE:-} ]]; then
        docker run --rm --network host --read-only --tmpfs /tmp -u "$(id -u):$(id -g)" -v "$tmp:$tmp" \
            -e CCS_WATCH_STATE -e CCS_WATCH_PULL -e CCS_WATCH_FORGE -e CCS_WATCH_WAITS \
            --entrypoint /opt/ccs-bash/contrib/ccs-watch "$CCS_WATCH_IMAGE" "$@"
    else
        "$here/../contrib/ccs-watch" "$@"
    fi
}

addr() { printf '%s%094d' "${2:-9}" "$1" | tr 0 z; }
# the signed list, its QR codes beside it (subaddresses.txt.qr/); ccs-bash's projects.json (what
# each proposal's box must show): "a b" funding required with the list's 1, "done" completed
mkdir -p "$tmp/out" "$tmp/list.txt.qr"
for i in 0 1 2; do echo "$i $(addr "$i")"; echo "qr of $i" > "$tmp/list.txt.qr/$(addr "$i").png"; done > "$tmp/list.txt"
printf '[{"filename":"a b.md","state":"FUNDING-REQUIRED","address":"%s"},{"filename":"done.md","state":"COMPLETED","address":null}]\n' "$(addr 1)" > "$tmp/out/projects.json"
# the site as the web server built it: the fixed pages, the General Fund (allowed) in a footer,
# the box with its address and the list's QR code of it
mkdir -p "$tmp/remote/proposals" "$tmp/remote/funding-required" "$tmp/remote/donate" "$tmp/remote/verify" "$tmp/remote/qr"
echo "<p>home</p><p class=\"address\">$(addr 3 8)</p>" > "$tmp/remote/index.html"
for d in funding-required donate verify; do echo "$d" > "$tmp/remote/$d/index.html"; done
echo "<a href=\"../index.html\">home</a><!-- ccs:donate --><details class=\"contribute\"><a class=\"qr\" href=\"monero:$(addr 1)\"><img src=\"../qr/$(addr 1).png\"></a><div class=\"address\">$(addr 1)</div></details><!-- /ccs:donate --><p class=\"address\">$(addr 3 8)</p><img src=\"../assets/fund-qr.png\">" > "$tmp/remote/proposals/a b.html"
echo "<p>the General Fund in the footer, no box</p><p class=\"address\">$(addr 3 8)</p>" > "$tmp/remote/proposals/done.html"
echo '[{"filename":"a b.md"}]' > "$tmp/remote/projects"
cp "$tmp/list.txt.qr/$(addr 1).png" "$tmp/remote/qr/"
echo '<p>not here</p>' > "$tmp/remote/404.html"
# /dark/ and /light/: the same pages (the web server's theme lines)
for t in dark light; do
    mkdir -p "$tmp/remote/$t"
    for f in index.html funding-required donate verify proposals qr projects; do ln -s "../$f" "$tmp/remote/$t/$f"; done
done

web=$(port) bot=$(port)
# the "web server": the files, a 404 for anything else, and the theme lines' redirects
# (?theme=dark|light|system: the same page under /dark/, /light/ or no prefix), as Caddy answers
python3 -c '
import http.server, os, re, sys, urllib.parse
class H(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        u = urllib.parse.urlsplit(self.path); t = urllib.parse.parse_qs(u.query).get("theme", [""])[0]
        if t in ("dark", "light", "system"):
            page = re.sub(r"^/(dark|light)(?=/)", "", u.path)
            self.send_response(302); self.send_header("Location", page if t == "system" else "/" + t + page)
            self.send_header("Content-Length", "0"); self.end_headers(); return
        super().do_GET()
    def send_error(self, code, *a, **k):
        if code != 404: return super().send_error(code, *a, **k)
        body = open("404.html", "rb").read()
        self.send_response(404); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
os.chdir(sys.argv[2]); http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()' "$web" "$tmp/remote" & pids+=($!)
python3 -c '
import http.server, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        with open(sys.argv[2], "ab") as f: f.write(self.path.encode() + b" " + self.rfile.read(n) + b"\n")
        self.send_response(200); self.end_headers()
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()' "$bot" "$tmp/bot.txt" & pids+=($!)
sleep 1
printf 'ALERT_URL=http://127.0.0.1:%s/simple?channel=%%23ccs\nSUBADDRESSES=%s\nWATCH_ALLOWED=%s\nALERT_PLAIN=1\nWATCH_THEMES=1\n' "$bot" "$tmp/list.txt" "$(addr 3 8)" > "$tmp/alert.conf"
watch() { CCS_WATCH_STATE=$tmp/state ccs_watch "http://127.0.0.1:$web" "$tmp/out" "$tmp/alert.conf" 2> "$tmp/log"; }
alerts() { [[ -f $tmp/bot.txt ]] && wc -l < "$tmp/bot.txt" || echo 0; }

# (busybox's sleep: whole seconds)
if [[ ${CCS_WATCH_IMAGE:-} ]]; then export CCS_WATCH_WAITS="1 1"; else export CCS_WATCH_WAITS="0.2 0.2"; fi
page=$tmp/remote/proposals/a\ b.html
if watch && [[ $(alerts) == 0 ]] && grep -q "the 5 pages on .*, and the 2 others: every address the wallet's, each donation box its proposal's" "$tmp/log"; then
    ok "every address the wallet's or allowed: no alert (5 pages: 4 fixed, 1 with a donation box; 2 others: the page without one, /projects)"
else cat "$tmp/log"; fail "a good site"; fi

# Never an alert for the web server being slow, down or answering nothing: those are failed
# fetches, not "differs".
cp "$page" "$tmp/page.good"
: > "$page"
for _ in 1 2; do watch || true; done
if [[ $(alerts) == 0 ]] && grep -q "could not fetch" "$tmp/log"; then ok "a page answering 200 with nothing, twice: no alert"; else cat "$tmp/log"; fail "an empty answer"; fi
rm -f "$tmp/state"/answers-*
# An answer over 16 MB (a web server filling the watcher's /tmp, which is memory): not kept, an
# answer that isn't the page (three in a row alert, as a wrong status does)
head -c 17000000 /dev/zero > "$page"
watch || true
if grep -q "could not fetch .*(HTTP with more than 16 MB)" "$tmp/log"; then ok "a page answering more than 16 MB: not kept, an answer that isn't the page"; else cat "$tmp/log"; fail "an answer over 16 MB"; fi
rm -f "$tmp/state"/answers-*   # (the 404s below are counted from none)
rm "$page"
for _ in 1 2; do watch || true; done
if [[ $(alerts) == 0 ]]; then ok "a page answering 404, twice: no alert"; else fail "a 404"; fi
# Security review 2026-10-25 (fails until fixed): a donation page that never answers 200 again (a
# web server sending it elsewhere, say) while the rest of the site does is never an alert
for _ in 1 2 3 4; do watch || true; done
if [[ $(alerts) == 1 ]]; then ok "a donation page answering 404 on six runs in a row: an alert"; else fail "a donation page gone for good, the rest of the site up: no alert"; fi
: > "$tmp/bot.txt"; rm -f "$tmp/state"/alert-* "$tmp/state/unreachable"
cp "$tmp/page.good" "$page"

# (Each run fetches a page under /, /dark/ or /light/ at random: the alerts are read without it.)
# A changed page alerts only when it stays changed: on three fetches over the waits, and on a
# later run within a day too.
sed -i "s/$(addr 1)/$(addr 7 B)/g" "$page"
watch || true
if [[ $(alerts) == 0 ]] && grep -q "alerting if it does again within a day" "$tmp/log"; then ok "a page changed: no alert on the first run that sees it"; else cat "$tmp/log"; fail "first sight"; fi
if ! watch && [[ $(alerts) == 1 ]] && grep -qF "/simple?channel=%23ccs [CCS-watch] donation address $(addr 7 B | sed -E 's/^(.{6}).*(.{4})$/\1…\2/') does not match the CCS wallet @ http://127.0.0.1:$web/proposals/a%20b.html" <(sed -E 's#/(dark|light)/#/#' "$tmp/bot.txt") \
    && ! grep -qF "$(addr 3 8 | cut -c1-6)" "$tmp/bot.txt"; then
    ok "still changed on the next run: one alert, naming the page and only the new address (not the General Fund)"
else
    cat "$tmp/log" "$tmp/bot.txt" 2> /dev/null; fail "a changed page"
fi
if ! watch && [[ $(alerts) == 1 ]]; then ok "still changed an hour later or less: no second alert"; else fail "a repeated alert"; fi
cp "$tmp/page.good" "$page"
if watch && [[ $(alerts) == 1 ]]; then ok "put back: no alert"; else fail "recovery"; fi
# Security review 5: a run that sees the right page doesn't clear what an earlier one saw (a web
# server showing its own page on every other push): changed again the same day, the first run
# that sees it alerts
rm -f "$tmp/state"/alert-*
sed -i "s/$(addr 1)/$(addr 7 B)/g" "$page"
watch || true
if [[ $(alerts) == 2 ]]; then ok "changed, put back, changed again within a day: the first run that sees it again alerts"; else cat "$tmp/log"; fail "a page changed every other run"; fi
cp "$tmp/page.good" "$page"; rm -f "$tmp/state"/differs-*
# Another of the list's addresses in the box (another proposal's): not its own, an alert on the
# second run; the list's QR code of another address in it, likewise; and (review 12's L-2) another
# image in the box, in place of its QR code or beside it
for c in "box|s/monero:$(addr 1)/monero:$(addr 2)/|the donation box isn't its proposal's address" "qr|qr|the donation box's QR code isn't the signed list's of its address" \
    "img|s#src=\"../qr/$(addr 1).png\"#src=\"../images/x.png\"#|the donation box shows another image than its address's QR code" \
    "two|s#</details>#<img src=\"../images/x.png\"></details>#|the donation box shows another image than its address's QR code"; do
    IFS='|' read -r what how why <<<"$c"
    : > "$tmp/bot.txt"; rm -f "$tmp/state"/alert-* "$tmp/state"/differs-*
    if [[ $what == qr ]]; then cp "$tmp/list.txt.qr/$(addr 2).png" "$tmp/remote/qr/$(addr 1).png"; else sed -i "$how" "$page"; fi
    watch || true; watch || true
    if [[ $(alerts) == 1 ]] && sed -E 's#/(dark|light)/#/#' "$tmp/bot.txt" | grep -qF "$why"; then ok "$why: an alert"; else cat "$tmp/log" "$tmp/bot.txt"; fail "$why"; fi
    cp "$tmp/page.good" "$page"; cp "$tmp/list.txt.qr/$(addr 1).png" "$tmp/remote/qr/"
done
# A proposal at its goal: the design's "Funded" in place of the box, no address of its own on the
# page (the General Fund's in the footer): nothing to alert
: > "$tmp/bot.txt"; rm -f "$tmp/state"/alert-* "$tmp/state"/differs-*
echo "<a href=\"../index.html\">home</a><!-- ccs:donate --><progress max=\"100\" value=\"100\">100%</progress><div class=\"contribute\"><span class=\"button primary funded\">Funded</span></div><!-- /ccs:donate --><a class=\"qr\" href=\"monero:$(addr 3 8)\"><img src=\"../assets/fund-qr.png\"></a>" > "$page"
watch || true; watch || true
if [[ $(alerts) == 0 ]]; then ok "a proposal at its goal (Funded, no box): no alert"; else cat "$tmp/log" "$tmp/bot.txt"; fail "a funded proposal's page"; fi
cp "$tmp/page.good" "$page"
: > "$tmp/bot.txt"; rm -f "$tmp/state"/alert-* "$tmp/state"/differs-*
# An address on a page that isn't a box's (a proposal's text, the footer): any one not the list's
# nor allowed alerts too
echo "<p>or send to $(addr 7 B)</p>" >> "$tmp/remote/proposals/done.html"
for _ in $(seq 20); do watch || true; [[ $(alerts) == 0 ]] || break; done
if [[ $(alerts) == 1 ]] && grep -qF "donation address $(addr 7 B | sed -E 's/^(.{6}).*(.{4})$/\1…\2/') does not match the CCS wallet" "$tmp/bot.txt"; then
    ok "a foreign address on a page without a box (seen when it is among the sampled ones): an alert"
else cat "$tmp/log" "$tmp/bot.txt"; fail "a foreign address in a page's text"; fi
sed -i '$d' "$tmp/remote/proposals/done.html"; : > "$tmp/bot.txt"; rm -f "$tmp/state"/alert-* "$tmp/state"/differs-*
# with the gate's scan (ccs-check, in the ccs-bash image), review 12's L-2: an address in groups,
# or written as entities, found as the gate finds it (a real one: groups are kept by checksum)
if [[ ${CCS_WATCH_IMAGE:-} ]] || command -v ccs-check > /dev/null; then
    real=9uH2Z776LeJ4gku967Y3o8VrBueTqSoQhDXVftRkU2Jt81du8DDNV4eAFmPaojQV4mhrgDBvzUfRX7EoHp245dNf9wimfPf
    for c in "in groups|$(for ((i = 0; i < 95; i += 4)); do printf '%s ' "${real:i:4}"; done)" "as entities|$(for ((i = 0; i < 95; i++)); do printf '&#%d;' "'${real:i:1}"; done)"; do
        IFS='|' read -r what text <<<"$c"
        echo "<p>or send to $text</p>" >> "$tmp/remote/proposals/done.html"
        for _ in $(seq 20); do watch || true; [[ $(alerts) == 0 ]] || break; done
        if [[ $(alerts) == 1 ]] && grep -qF "donation address ${real:0:6}…${real: -4} does not match the CCS wallet" "$tmp/bot.txt"; then
            ok "a foreign address $what on a page: found as the gate finds it, an alert"
        else cat "$tmp/log" "$tmp/bot.txt"; fail "a foreign address $what"; fi
        sed -i '$d' "$tmp/remote/proposals/done.html"; : > "$tmp/bot.txt"; rm -f "$tmp/state"/alert-* "$tmp/state"/differs-*
    done
fi

# Changed for a moment only (a push landing): put back before the recheck, never alerts.
rm -f "$tmp/state"/alert-*; base=$(alerts)
for _ in 1 2; do
    sed -i "s/$(addr 1)/$(addr 7 B)/g" "$page"
    (sleep 0.1; cp "$tmp/page.good" "$page") & putback=$!
    watch || true; wait "$putback"
done
if [[ $(alerts) == "$base" ]]; then ok "changed for a moment on two runs: no alert"; else cat "$tmp/bot.txt"; fail "a moment's change"; fi

# The web server goes away while a changed page is being rechecked: nothing is known, no alert.
sed -i "s/$(addr 1)/$(addr 7 B)/g" "$page"
watch || true   # first sight
kill "${pids[0]}"; wait "${pids[0]}" 2> /dev/null || true
watch || true   # second run: it can't fetch at all now
if [[ $(alerts) == "$base" ]]; then ok "changed, then the web server down: no alert for the change"; else cat "$tmp/bot.txt"; fail "changed then down"; fi

# Down: an alert only after three checks in a row that reached nothing at all.
for _ in 1 2; do watch || true; done
if [[ $(alerts) == $((base + 1)) ]] && tail -n 1 "$tmp/bot.txt" | grep -qF "[CCS-watch] http://127.0.0.1:$web could not be fetched (3 checks in a row)"; then
    ok "the site down three checks in a row: one alert"
else
    cat "$tmp/bot.txt"; fail "unreachable"
fi

# The backend stopping: the push stage reports each run (--run). Nothing for one or two failed
# runs; the third alerts, once; the first good run after it says so; a good run before that, nothing.
run() { CCS_WATCH_STATE=$tmp/runstate CCS_WATCH_PULL=$tmp/pull-ok CCS_WATCH_FORGE=$tmp/forge-ok ccs_watch --run "$1" "$tmp/alert.conf" 2>> "$tmp/log"; }
before=$(alerts)
run ccs-bash; run ccs-bash
if [[ $(alerts) == "$before" ]]; then ok "the backend failing twice in a row: no alert"; else fail "two failed runs"; fi
run "ccs-bash, the push"
if [[ $(alerts) == $((before + 1)) ]] && tail -n 1 "$tmp/bot.txt" | grep -qE "\[CCS-watch\] the backend has failed 3 runs in a row since [0-9-]+ [0-9:]+ UTC: ccs-bash, the push \(ccs log on the backend\)"; then
    ok "the third failed run in a row: one alert, with what failed"
else
    tail -n 2 "$tmp/bot.txt" 2> /dev/null; fail "three failed runs"
fi
run ccs-bash; run ccs-bash
if [[ $(alerts) == $((before + 1)) ]]; then ok "still failing within the hour: no second alert"; else fail "a repeated alert"; fi
run ok
if [[ $(alerts) == $((before + 2)) ]] && tail -n 1 "$tmp/bot.txt" | grep -qF "[CCS-watch] the backend runs again, after 5 failed runs"; then ok "the first good run after the alert: says so"; else tail -n 1 "$tmp/bot.txt"; fail "recovery"; fi
run ccs-front-bash; run ok; run ok
if [[ $(alerts) == $((before + 2)) ]]; then ok "one failed run, then good ones: nothing"; else fail "a blip"; fi

# GitLab or Forgejo down: not a failed run, nothing at first; a pull or API answer FORGE_HOURS (6)
# ago alerts, naming which, once an hour; both answering again says so. Never answered yet: nothing.
before=$(alerts)
run ok
if [[ $(alerts) == "$before" ]]; then ok "forge: no pull-ok or forge-ok yet: nothing known, no alert"; else fail "forge before any answer"; fi
touch "$tmp/pull-ok" && touch -d '-5 hours' "$tmp/forge-ok"
run ok
if [[ $(alerts) == "$before" ]]; then ok "forge: the API down for 5 hours: no alert yet"; else fail "forge within FORGE_HOURS"; fi
touch -d '-7 hours' "$tmp/forge-ok"
run ok; run ok
if [[ $(alerts) == $((before + 1)) ]] && tail -n 1 "$tmp/bot.txt" | grep -qE "\[CCS-watch\] GitLab/Forgejo hasn't answered for over 6h: its API \(Ideas, merge requests\) since [0-9-]+ [0-9:]+ UTC\. New merged proposals and Ideas aren't on the site" \
    && ! tail -n 1 "$tmp/bot.txt" | grep -q 'git pull'; then
    ok "forge: the API down for 7 hours: one alert, naming it (not the pull, which works), not repeated within the hour"
else
    tail -n 2 "$tmp/bot.txt"; fail "forge down"
fi
touch "$tmp/forge-ok"
run ok
if [[ $(alerts) == $((before + 2)) ]] && tail -n 1 "$tmp/bot.txt" | grep -qF "[CCS-watch] GitLab/Forgejo answers again"; then ok "forge: answering again: says so"; else tail -n 1 "$tmp/bot.txt"; fail "forge recovery"; fi
run ok
if [[ $(alerts) == $((before + 2)) ]]; then ok "forge: up, then up: nothing more"; else fail "forge: a repeated recovery"; fi
rm -f "$tmp/runstate"/alert-forge*
touch -d '-3 hours' "$tmp/pull-ok"; printf 'FORGE_HOURS=2\n' >> "$tmp/alert.conf"
run ok
if [[ $(alerts) == $((before + 3)) ]] && tail -n 1 "$tmp/bot.txt" | grep -qF "over 2h: the proposals repository (git pull) since"; then ok "forge: FORGE_HOURS=2, the pull failing for 3 hours: alert"; else tail -n 1 "$tmp/bot.txt"; fail "FORGE_HOURS"; fi
sed -i '/^FORGE_HOURS=/d' "$tmp/alert.conf"

# wmb's /directedMessage: JSON with the target, the message and the password (on stdin, so not
# in any command line ps shows), and --test sends one message to check the setup
printf 'ALERT_URL=http://127.0.0.1:%s/directedMessage\nALERT_TARGET=#irc-room\nALERT_PASSWORD=s3cr3t\n' "$bot" > "$tmp/wmb.conf"
: > "$tmp/bot.txt"
if ccs_watch --test https://ccs.test/ "$tmp/wmb.conf" > /dev/null \
    && jq -e '.Target == "#irc-room" and .IncomingMessage.Password == "s3cr3t"
              and (.IncomingMessage.Message == "[\u000312CCS-watch\u0003] test, please ignore @ https://ccs.test/")' \
        <(cut -d' ' -f2- "$tmp/bot.txt") > /dev/null \
    && ! grep -q 's3cr3t' "$here/../contrib/ccs-watch"; then
    ok "wmb: the JSON it wants (IRC colours on: the tag light blue), and --test sends one message"
else
    cat "$tmp/bot.txt"; fail "wmb"
fi
# Asked for as Tor Browser asks: a page as a page, an image as one (a web server can't pick out
# the watcher by a missing Sec-Fetch-* header)
hdr=$(port); mkdir -p "$tmp/h/site/proposals" "$tmp/h/site/qr" "$tmp/h/out"
echo '<p>home</p>' > "$tmp/h/site/index.html"
cp "$tmp/page.good" "$tmp/h/site/proposals/a b.html" && cp "$tmp/remote/qr/$(addr 1).png" "$tmp/h/site/qr/" && cp "$tmp/out/projects.json" "$tmp/h/out/"
python3 -c '
import http.server, sys, os
class H(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        with open(sys.argv[2], "a") as f: f.write(self.path + " " + "|".join(k + ": " + v for k, v in self.headers.items()) + "\n")
        super().do_GET()
    def log_message(self, *a): pass
os.chdir(sys.argv[3]); http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()' "$hdr" "$tmp/h/seen" "$tmp/h/site" & pids+=($!)
sleep 1
printf 'SUBADDRESSES=%s\nWATCH_ALLOWED=%s\n' "$tmp/list.txt" "$(addr 3 8)" > "$tmp/h/alert.conf"
CCS_WATCH_STATE=$tmp/h/state ccs_watch "http://127.0.0.1:$hdr" "$tmp/h/out" "$tmp/h/alert.conf" 2> "$tmp/h/log" || true
if grep -qE '^/ .*Sec-Fetch-Dest: document\|Sec-Fetch-Mode: navigate\|Sec-Fetch-Site: (none|same-origin|cross-site)\|Sec-Fetch-User: \?1' "$tmp/h/seen" \
    && grep -q '^/ .*Upgrade-Insecure-Requests: 1' "$tmp/h/seen" && grep -q "^/qr/$(addr 1).png .*Sec-Fetch-Dest: image" "$tmp/h/seen" \
    && ! grep -q "^/qr/.*Sec-Fetch-User" "$tmp/h/seen"; then
    ok "asked for as Tor Browser asks: a page with Sec-Fetch-Dest: document, the box's QR code with image"
else
    cut -c1-60 "$tmp/h/seen"; cat "$tmp/h/log"; fail "the headers a page and an image are asked for with"
fi
# Visitors reach a donation page from the site's own lists (Sec-Fetch-Site: same-origin) or from
# another site (cross-site), not only typed in (none): a web server that changes the page only for
# those must not be invisible to the watcher. Over ten runs, some fetches of it as a click-through.
: > "$tmp/h/seen"
for _ in $(seq 10); do CCS_WATCH_STATE=$tmp/h/state ccs_watch "http://127.0.0.1:$hdr" "$tmp/h/out" "$tmp/h/alert.conf" 2> /dev/null || true; done
if grep -qE '^/proposals/a%20b.html .*Sec-Fetch-Site: (same-origin|cross-site)' "$tmp/h/seen"; then
    ok "a donation page is sometimes asked for as a visitor clicking through to it"
else
    fail "a donation page only ever asked for as typed in (Sec-Fetch-Site: none): a web server can tell the watcher"
fi
# A page that doesn't exist: answered 404 (as Caddy's error page does), no alert; the web
# server's own page there instead (FAKE set), an alert on the second run
mkdir -p "$tmp/n/site" "$tmp/n/out" && echo '<p>home</p>' > "$tmp/n/site/index.html" && echo '[]' > "$tmp/n/out/projects.json"
echo '<p>not here</p>' > "$tmp/n/site/404.html"
nf=$(port)
python3 -c '
import http.server, os, sys
class H(http.server.SimpleHTTPRequestHandler):
    def send_error(self, code, *a, **k):
        if code != 404: return super().send_error(code, *a, **k)
        fake = os.path.exists(sys.argv[2])
        body = b"<p>Donate here</p>" if fake else open("404.html", "rb").read()
        self.send_response(200 if fake else 404); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
os.chdir(sys.argv[3]); http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()' "$nf" "$tmp/n/FAKE" "$tmp/n/site" & pids+=($!)
sleep 1
printf 'ALERT_URL=http://127.0.0.1:%s/simple?channel=%%23ccs\nALERT_PLAIN=1\nSUBADDRESSES=%s\n' "$bot" "$tmp/list.txt" > "$tmp/n/alert.conf"
nwatch() { CCS_WATCH_STATE=$tmp/n/state ccs_watch "http://127.0.0.1:$nf" "$tmp/n/out" "$tmp/n/alert.conf" 2> "$tmp/n/log"; }
before=$(alerts)
nwatch || true; nwatch || true
if [[ $(alerts) == "$before" ]] && ! grep -q "doesn't exist" "$tmp/n/log"; then
    ok "a page that doesn't exist answers 404: no alert"
else cat "$tmp/n/log"; fail "a 404 page"; fi
touch "$tmp/n/FAKE"
nwatch || true; first=$(alerts); nwatch || true
if [[ $first == "$before" && $(alerts) == $((before + 1)) ]] && tail -n 1 "$tmp/bot.txt" | grep -q "a page that doesn't exist answers HTTP 200, not a 404"; then
    ok "the web server's own page at a path that doesn't exist: an alert, on the second run that sees it"
else cat "$tmp/n/log"; tail -n 2 "$tmp/bot.txt"; fail "a page that doesn't exist"; fi

# Security review 5 (2026-10-27): a web server (attacker 2) that serves visitors a foreign address
# on a donation page while trying to hide it from the watcher. One local "web server" as nginx
# answers (/dark/ and /light/ the same files, ?theme= redirects, the 404 page for anything not
# there), its trick named in $tmp/e/MODE:
#   refuse-repeat  the foreign page to everyone, but a second ask for the same page within 5s (the
#                  watcher's recheck) answers 503
#   toggle         the foreign page while $tmp/e/EVIL exists: on every other push
#   after-unpushed the foreign page from the watcher's ask for a page never pushed until the next
#                  push ($tmp/e/PUSH): the watcher's last ask, if it were always the last
#   browser        the foreign page to every browser but Tor Browser
#   unpushed       its own page at every name never pushed but a 12-hex-digit one
#   theme          the theme button sends visitors elsewhere
mkdir -p "$tmp/e/site/proposals" "$tmp/e/out"
echo '<p>not here</p>' > "$tmp/e/site/404.html"; echo '<p>home</p>' > "$tmp/e/site/index.html"
printf '[{"filename":"p.md","state":"FUNDING-REQUIRED","address":"%s"}]\n' "$(addr 1)" > "$tmp/e/out/projects.json"
for d in funding-required donate verify; do mkdir -p "$tmp/e/site/$d" && echo "$d" > "$tmp/e/site/$d/index.html"; done; echo '[]' > "$tmp/e/site/projects"
mkdir -p "$tmp/e/site/qr" && cp "$tmp/list.txt.qr/$(addr 1).png" "$tmp/e/site/qr/"
echo "<!-- ccs:donate --><details class=\"contribute\"><a href=\"monero:$(addr 1)\"><img src=\"../qr/$(addr 1).png\"></a><div class=\"address\">$(addr 1)</div></details><!-- /ccs:donate -->" > "$tmp/e/site/proposals/p.html"
sed "s/$(addr 1)/$(addr 7 B)/g" "$tmp/e/site/proposals/p.html" > "$tmp/e/evil.html"
ep=$(port)
python3 -c '
import http.server, os, re, sys, time, urllib.parse
d = sys.argv[2]; seen = {}; state = {"unpushed": 0.0}
class H(http.server.BaseHTTPRequestHandler):
    def send_body(self, code, body, extra=()):
        self.send_response(code)
        for k, v in extra: self.send_header(k, v)
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def do_GET(self):
        m = open(os.path.join(d, "MODE")).read().strip(); ua = self.headers.get("User-Agent", "")
        with open(os.path.join(d, "agents"), "a") as f: f.write(ua + "\n")
        u = urllib.parse.urlsplit(self.path); t = urllib.parse.parse_qs(u.query).get("theme", [""])[0]
        path = re.sub(r"^/(dark|light)(?=/)", "", urllib.parse.unquote(u.path))
        if t:
            if m == "theme": return self.send_body(302, b"", [("Location", "/elsewhere/")])
            return self.send_body(302, b"", [("Location", (u.path if t == "system" else "/" + t + u.path) if not re.match(r"^/(dark|light)/", u.path) else re.sub(r"^/(dark|light)", "" if t == "system" else "/" + t, u.path))])
        f = os.path.join(d, "site", path.lstrip("/"))
        if f.endswith("/"): f += "index.html"
        evil = open(os.path.join(d, "evil.html"), "rb").read()
        if not os.path.isfile(f):
            if m == "unpushed" and not re.fullmatch(r"/proposals/[0-9a-f]{12}\.html", path): return self.send_body(200, b"<p>Donate here</p>")
            state["unpushed"] = time.time()
            return self.send_body(404, open(os.path.join(d, "site/404.html"), "rb").read())
        if path == "/proposals/p.html":
            if m == "refuse-repeat":
                k = self.client_address[0]; last = seen.get(k, 0); seen[k] = time.time()
                if time.time() - last < 5: return self.send_body(503, b"")
                return self.send_body(200, evil)
            if m == "toggle" and os.path.exists(os.path.join(d, "EVIL")): return self.send_body(200, evil)
            if m == "after-unpushed" and state["unpushed"] > os.path.getmtime(os.path.join(d, "PUSH")): return self.send_body(200, evil)
            if m == "browser" and "(Windows NT 10.0; rv:" not in ua: return self.send_body(200, evil)
        self.send_body(200, open(f, "rb").read())
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()' "$ep" "$tmp/e" & pids+=($!)
echo none > "$tmp/e/MODE"; touch "$tmp/e/PUSH"
sleep 1
printf 'ALERT_URL=http://127.0.0.1:%s/simple?channel=%%23ccs\nALERT_PLAIN=1\nWATCH_SAMPLE=0\nWATCH_THEMES=1\nSUBADDRESSES=%s\n' "$bot" "$tmp/list.txt" > "$tmp/e/alert.conf"
# a run right after a push (the update script's), and one between pushes (ccs-watch.timer's)
ewatch() { CCS_WATCH_STATE=$tmp/e/state ccs_watch "http://127.0.0.1:$ep" "$tmp/e/out" "$tmp/e/${econf:-alert.conf}" 2> "$tmp/e/log" || true; }
push() { touch "$tmp/e/PUSH"; sleep 0.05; ewatch; }
# a visitor (Chrome) asking for the donation page: does it get the foreign address?
visitor() { curl -s -A 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36' "http://127.0.0.1:$ep/proposals/p.html" | grep -c "$(addr 7 B)" || true; }
echo none > "$tmp/e/MODE"; rm -rf "$tmp/e/state"; : > "$tmp/bot.txt"; push; push
if [[ $(alerts) == 0 ]] && grep -q "every address the wallet's" "$tmp/e/log"; then ok "review 5: the test's web server, honest: no alert"; else cat "$tmp/e/log" "$tmp/bot.txt"; fail "review 5: the honest web server"; fi
etry() {   # etry MODE RUNS WHAT: RUNS pushes, each with a timer run after it; a visitor looks in between
    local seen=0 i
    echo "$1" > "$tmp/e/MODE"; rm -rf "$tmp/e/state" "$tmp/e/EVIL"; : > "$tmp/bot.txt"; sleep 5
    for ((i = 1; i <= $2; i++)); do
        push; [[ $1 == refuse-repeat ]] && sleep 5
        ewatch; [[ $1 == refuse-repeat ]] && sleep 5
        (($(visitor) > 0)) && seen=$((seen + 1))
        [[ $1 == refuse-repeat ]] && sleep 5
    done
    if ((seen == 0)); then fail "review 5: $1: the test's web server didn't serve the visitor the foreign page"
    elif [[ $(alerts) == 0 ]]; then cat "$tmp/e/log"; fail "review 5: $3 (a visitor saw the foreign address after $seen of $2 pushes; no alert)"
    else ok "review 5: $3: an alert"; fi
}
etry refuse-repeat 2 "the foreign page to everyone, a 503 for the watcher's recheck"
# every other run, each run right after a push and no other, without the themes (one address per
# page): every run that sees the right page used to clear what the one before saw
grep -v WATCH_THEMES "$tmp/e/alert.conf" > "$tmp/e/plain.conf"
echo toggle > "$tmp/e/MODE"; rm -rf "$tmp/e/state"; : > "$tmp/bot.txt"; seen=0
for i in 1 2 3 4; do
    if ((i % 2)); then touch "$tmp/e/EVIL"; else rm -f "$tmp/e/EVIL"; fi
    econf=plain.conf push
    (($(visitor) > 0)) && seen=$((seen + 1))
done
rm -f "$tmp/e/EVIL"
if ((seen == 2)) && [[ $(alerts) != 0 ]]; then ok "review 5: the foreign page on every other push: an alert"; else cat "$tmp/e/log"; fail "review 5: the foreign page on every other push (seen $seen times; no alert)"; fi
etry after-unpushed 2 "the foreign page from the watcher's ask for a page never pushed until the next push"
etry browser 6 "the foreign page to every browser but Tor Browser"
echo unpushed > "$tmp/e/MODE"; rm -rf "$tmp/e/state"; : > "$tmp/bot.txt"; push; push
if [[ $(curl -s "http://127.0.0.1:$ep/proposals/ccs-fund-raise.html") == "<p>Donate here</p>" ]] && grep -q "a page that doesn't exist answers HTTP 200" "$tmp/bot.txt"; then
    ok "review 5: its own page at every name that doesn't exist but a 12-hex-digit one: an alert"
else cat "$tmp/e/log"; fail "review 5: never-pushed names"; fi
echo theme > "$tmp/e/MODE"; rm -rf "$tmp/e/state"; : > "$tmp/bot.txt"; push; push
if grep -q "the theme button sends visitors to http://127.0.0.1:$ep/elsewhere/" "$tmp/bot.txt"; then ok "review 5: the theme button sending visitors elsewhere: an alert"; else cat "$tmp/e/log"; fail "review 5: the theme button's redirect"; fi
if (($(sort -u "$tmp/e/agents" | grep -c .) >= 2)); then ok "review 5: asked for as more than one browser over the runs"; else sort -u "$tmp/e/agents"; fail "review 5: one browser only"; fi
exit "$status"

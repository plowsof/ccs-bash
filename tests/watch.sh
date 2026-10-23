#!/usr/bin/env bash
# contrib/ccs-watch against a local "web server" (python3 http.server) and a fake bot that keeps
# what it is sent: nothing changed, no alert; a page changed there, an alert naming it and the
# address that isn't the wallet's, once an hour; the site down three times, an alert.
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
tmp=$(mktemp -d)
pids=()
trap 'kill "${pids[@]}" 2> /dev/null || true; [[ ${SHOW:-} ]] && cat "$tmp/bot.txt"; rm -rf "$tmp"' EXIT
status=0
ok() { echo "ok   $1"; }
fail() { echo "FAIL $1"; status=1; }
port() { python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }

addr() { printf '%s%094d' "${2:-9}" "$1" | tr 0 1; }
mkdir -p "$tmp/local/proposals" "$tmp/local/funding-required" "$tmp/local/donate" "$tmp/local/verify"
for i in 0 1 2; do echo "$i $(addr "$i")"; done > "$tmp/list.txt"
echo home > "$tmp/local/index.html"
for d in funding-required donate verify; do echo "$d" > "$tmp/local/$d/index.html"; done
# a donation box, and the General Fund in the footer (on every page, not the wallet's)
echo "<details class=\"contribute\"><a class=\"qr\" href=\"monero:$(addr 1)\"></a><div class=\"address\">$(addr 1)</div></details><p class=\"address\">$(addr 3 8)</p>" > "$tmp/local/proposals/a b.html"
echo "<a class=\"qr\" href=\"monero:$(addr 0)\"></a> the General Fund in the footer, no Contribute box" > "$tmp/local/proposals/done.html"
cp -r "$tmp/local" "$tmp/remote"

web=$(port) bot=$(port)
python3 -m http.server "$web" --bind 127.0.0.1 -d "$tmp/remote" > /dev/null 2>&1 & pids+=($!)
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
printf 'ALERT_URL=http://127.0.0.1:%s/simple?channel=%%23ccs\nSUBADDRESSES=%s\nALERT_PLAIN=1\n' "$bot" "$tmp/list.txt" > "$tmp/alert.conf"
watch() { CCS_WATCH_STATE=$tmp/state "$here/../contrib/ccs-watch" "http://127.0.0.1:$web" "$tmp/local" "$tmp/alert.conf" 2> "$tmp/log"; }
alerts() { [[ -f $tmp/bot.txt ]] && wc -l < "$tmp/bot.txt" || echo 0; }

export CCS_WATCH_WAITS="0.2 0.2"
page=$tmp/remote/proposals/a\ b.html
if watch && [[ $(alerts) == 0 ]] && grep -q "the 5 pages" "$tmp/log"; then ok "nothing changed: no alert (5 pages: 4 fixed, 1 with a donation box)"; else cat "$tmp/log"; fail "unchanged site"; fi

# Never an alert for the web server being slow, down or answering nothing: those are failed
# fetches, not "differs".
cp "$page" "$tmp/page.good"
: > "$page"
for _ in 1 2; do watch || true; done
if [[ $(alerts) == 0 ]] && grep -q "could not fetch" "$tmp/log"; then ok "a page answering 200 with nothing, twice: no alert"; else cat "$tmp/log"; fail "an empty answer"; fi
rm "$page"
for _ in 1 2; do watch || true; done
if [[ $(alerts) == 0 ]]; then ok "a page answering 404, twice: no alert"; else fail "a 404"; fi
cp "$tmp/page.good" "$page"

# A changed page alerts only when it stays changed: on three fetches over the waits, and on the
# next run too.
sed -i "s/$(addr 1)/$(addr 7 B)/g" "$page"
watch || true
if [[ $(alerts) == 0 ]] && grep -q "alerting if it still does next run" "$tmp/log"; then ok "a page changed: no alert on the first run that sees it"; else cat "$tmp/log"; fail "first sight"; fi
if ! watch && [[ $(alerts) == 1 ]] && grep -qF "/simple?channel=%23ccs [CCS-watch] donation address $(addr 7 B | sed -E 's/^(.{6}).*(.{4})$/\1…\2/') does not match the CCS wallet @ http://127.0.0.1:$web/proposals/a%20b.html" "$tmp/bot.txt" \
    && ! grep -qF "$(addr 3 8 | cut -c1-6)" "$tmp/bot.txt"; then
    ok "still changed on the next run: one alert, naming the page and only the new address (not the General Fund)"
else
    cat "$tmp/log" "$tmp/bot.txt" 2> /dev/null; fail "a changed page"
fi
if ! watch && [[ $(alerts) == 1 ]]; then ok "still changed an hour later or less: no second alert"; else fail "a repeated alert"; fi
cp "$tmp/page.good" "$page"
if watch && [[ ! -e $tmp/state/differs-proposals_a_b.html ]]; then ok "put back: the page is clean again"; else fail "recovery"; fi

# Changed for a moment only (a push landing): put back before the recheck, never alerts.
rm -f "$tmp/state"/alert-*
for _ in 1 2; do
    sed -i "s/$(addr 1)/$(addr 7 B)/g" "$page"
    (sleep 0.1; cp "$tmp/page.good" "$page") & putback=$!
    watch || true; wait "$putback"
done
if [[ $(alerts) == 1 ]]; then ok "changed for a moment on two runs: no alert"; else cat "$tmp/bot.txt"; fail "a moment's change"; fi

# The web server goes away while a changed page is being rechecked: nothing is known, no alert.
sed -i "s/$(addr 1)/$(addr 7 B)/g" "$page"
watch || true   # first sight
kill "${pids[0]}"; wait "${pids[0]}" 2> /dev/null || true
watch || true   # second run: it can't fetch at all now
if [[ $(alerts) == 1 ]]; then ok "changed, then the web server down: no alert for the change"; else cat "$tmp/bot.txt"; fail "changed then down"; fi

# Down: an alert only after three checks in a row that reached nothing at all.
for _ in 1 2; do watch || true; done
if [[ $(alerts) == 2 ]] && tail -n 1 "$tmp/bot.txt" | grep -qF "[CCS-watch] http://127.0.0.1:$web could not be fetched (3 checks in a row)"; then
    ok "the site down three checks in a row: one alert"
else
    cat "$tmp/bot.txt"; fail "unreachable"
fi

# wmb's /directedMessage: JSON with the target, the message and the password (on stdin, so not
# in any command line ps shows), and --test sends one message to check the setup
printf 'ALERT_URL=http://127.0.0.1:%s/directedMessage\nALERT_TARGET=#monero-ccs-emojis\nALERT_PASSWORD=s3cr3t\n' "$bot" > "$tmp/wmb.conf"
: > "$tmp/bot.txt"
if "$here/../contrib/ccs-watch" --test "$tmp/wmb.conf" > /dev/null \
    && jq -e '.Target == "#monero-ccs-emojis" and .IncomingMessage.Password == "s3cr3t"
              and (.IncomingMessage.Message | startswith("[\u000312CCS-watch\u0003] test, please ignore @ "))' \
        <(cut -d' ' -f2- "$tmp/bot.txt") > /dev/null \
    && ! grep -q 's3cr3t' "$here/../contrib/ccs-watch"; then
    ok "wmb: the JSON it wants (IRC colours on: the tag light blue), and --test sends one message"
else
    cat "$tmp/bot.txt"; fail "wmb"
fi
exit "$status"

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
echo "<details class=\"contribute\"><a class=\"qr\" href=\"monero:$(addr 1)\"></a><div class=\"address\">$(addr 1)</div></details>" > "$tmp/local/proposals/a b.html"
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
printf 'ALERT_URL=http://127.0.0.1:%s/simple?channel=%%23ccs\nSUBADDRESSES=%s\n' "$bot" "$tmp/list.txt" > "$tmp/alert.conf"
watch() { CCS_WATCH_STATE=$tmp/state "$here/../contrib/ccs-watch" "http://127.0.0.1:$web" "$tmp/local" "$tmp/alert.conf" 2> "$tmp/log"; }
alerts() { [[ -f $tmp/bot.txt ]] && wc -l < "$tmp/bot.txt" || echo 0; }

if watch && [[ $(alerts) == 0 ]] && grep -q "the 5 pages" "$tmp/log"; then ok "nothing changed: no alert (5 pages: 4 fixed, 1 with a donation box)"; else cat "$tmp/log"; fail "unchanged site"; fi

sed -i "s/$(addr 1)/$(addr 7 B)/g" "$tmp/remote/proposals/a b.html"
if ! watch && [[ $(alerts) == 1 ]] && grep -qF "/simple?channel=%23ccs [CCS Proposals] ccs-watch: donation address $(addr 7 B | sed -E 's/^(.{6}).*(.{4})$/\1…\2/') does not match the CCS wallet @ http://127.0.0.1:$web/proposals/a%20b.html" "$tmp/bot.txt"; then
    ok "a page changed on the web server: the bot is told which, and the address that isn't the wallet's"
else
    cat "$tmp/log" "$tmp/bot.txt" 2> /dev/null; fail "a changed page"
fi
if ! watch && [[ $(alerts) == 1 ]]; then ok "still changed an hour later or less: no second alert"; else fail "a repeated alert"; fi

kill "${pids[0]}"; sleep 0.5
for _ in 1 2 3; do watch || true; done
if [[ $(alerts) == 2 ]] && tail -n 1 "$tmp/bot.txt" | grep -qF "[CCS Proposals] ccs-watch: http://127.0.0.1:$web could not be fetched (3 checks in a row)"; then ok "the site down three checks in a row: an alert"; else cat "$tmp/bot.txt"; fail "unreachable"; fi
exit "$status"

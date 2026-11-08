#!/usr/bin/env bash
# The web server compose's www (contrib/docker/web/Caddyfile) in the gate's image, serving a site.
# It must give every answer nginx gave before it (docs/two-machines.md): the security headers, no
# server name, the cache rules, gzip, /projects, the theme's /dark/ and /light/ copies and
# redirects (never to another site), the 404 page, and the onion's socket.
# GATE_IMAGE: the image (ccs-gate). CADDYFILE: a Caddyfile to try instead of the image's
# (contrib/docker/web/Caddyfile, say).
set -euo pipefail
image=${GATE_IMAGE:-ccs-gate}
status=0
ok() { echo "ok   $*"; }
fail() { echo "FAIL $*"; status=1; }
t=$(mktemp -d)
name=ccs-www-test-$$
trap 'docker container rm -f "$name" > /dev/null 2>&1 || true; rm -rf "$t"' EXIT

h=$(printf '%064d' 7)
mkdir -p "$t/srv/assets" "$t/srv/proposals" "$t/onion" "$t/data" "$t/sites"
echo '<!doctype html><title>home</title>' > "$t/srv/index.html"
echo '<!doctype html><title>not found</title>' > "$t/srv/404.html"
echo '<!doctype html><title>a proposal</title>' > "$t/srv/proposals/a.html"
echo '<!doctype html><title>a proposal</title>' > "$t/srv/proposals/b-(2022).html"
printf 'body{color:red}%.0s' $(seq 200) > "$t/srv/assets/style.$h.css"
echo 'dark' > "$t/srv/assets/theme-dark.css"
echo 'light' > "$t/srv/assets/theme-light.css"
echo 'qr' > "$t/srv/assets/general-fund-qr.png"
echo '[{"filename":"a.md"}]' > "$t/srv/projects.json"
chmod -R a+rX "$t/srv"; chmod 777 "$t/onion" "$t/data"; chmod 755 "$t/sites"

onion=$(printf 'a%.0s' $(seq 56)).onion
docker run -d --name "$name" --network none --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges \
    --user 10010:10010 -e CCS_SITE_HOST=http://127.0.0.1:18080 -e CCS_ONION="$onion" -e CCS_ACME_EMAIL=test@example.invalid \
    -e HOME=/tmp -e XDG_CONFIG_HOME=/tmp \
    -v "$t/srv:/srv:ro" -v "$t/data:/data" -v "$t/onion:/run/ccs-www" -v "$t/sites:/etc/ccs-www/sites:ro" \
    ${CADDYFILE:+-v "$(readlink -f "$CADDYFILE"):/etc/caddy/Caddyfile:ro"} \
    --entrypoint /usr/bin/caddy "$image" run --config /etc/caddy/Caddyfile --adapter caddyfile > /dev/null
for _ in $(seq 50); do docker exec "$name" test -S /run/ccs-www/onion.sock 2> /dev/null && break; sleep 0.2; done
# get [CURL ARGS] PATH: print the response headers (lower-cased names), a blank line, then the body
get() { docker exec "$name" curl -sS -D - "${@:1:$#-1}" "http://127.0.0.1:18080${!#}" | tr -d '\r'; }
onion_get() { docker exec "$name" curl -sS -D - --unix-socket /run/ccs-www/onion.sock "http://$onion$1" | tr -d '\r'; }
hdr() { sed -n '/^$/q; p' <<<"$1" | grep -i "^$2:" | head -n 1 | cut -d' ' -f2-; }
code() { head -n 1 <<<"$1" | cut -d' ' -f2; }
body() { sed '1,/^$/d' <<<"$1"; }

r=$(get /) || { docker logs "$name" 2>&1 | tail -n 20; fail "www: no answer"; exit 1; }
csp="default-src 'none'; style-src 'self'; img-src 'self'; font-src 'self'; frame-ancestors 'none'; base-uri 'self'; form-action 'none'"
if [[ $(code "$r") == 200 && $(hdr "$r" content-security-policy) == "$csp" && $(hdr "$r" x-content-type-options) == nosniff \
    && $(hdr "$r" x-frame-options) == DENY && $(hdr "$r" referrer-policy) == no-referrer && $(hdr "$r" x-xss-protection) == 0 \
    && $(hdr "$r" permissions-policy) == "accelerometer=(), "*"xr-spatial-tracking=()" \
    && $(hdr "$r" strict-transport-security) == "max-age=31536000; includeSubDomains" \
    && $(hdr "$r" onion-location) == "http://$onion/" && $(hdr "$r" cache-control) == no-cache \
    && $(hdr "$r" content-type) == "text/html; charset=utf-8" && -z $(hdr "$r" server) && $(body "$r") == *"<title>home"* ]]; then
    ok "www: a page with every security header, its onion's address, no-cache, and no server name"
else echo "$r"; fail "www: a page's headers"; fi

r=$(get -H 'Accept-Encoding: gzip' -o /dev/null "/assets/style.$h.css")
if [[ $(hdr "$r" cache-control) == "public, max-age=31536000, immutable" && $(hdr "$r" content-encoding) == gzip \
    && $(hdr "$r" content-type) == "text/css; charset=utf-8" ]]; then
    ok "www: a file named by its sum cached for a year, and its text gzipped"
else echo "$r" | head -n 12; fail "www: the cache rule for a summed file, or gzip"; fi
r=$(get /assets/general-fund-qr.png)
if [[ $(hdr "$r" cache-control) == "public, max-age=86400" ]]; then ok "www: the General Fund's QR code cached for a day"
else echo "$r" | head -n 8; fail "www: the General Fund QR code's cache rule"; fi

r=$(get /projects)
if [[ $(code "$r") == 200 && $(hdr "$r" content-type) == application/json && $(hdr "$r" cache-control) == "no-cache, must-revalidate" \
    && $(body "$r") == '[{"filename":"a.md"}]' && $(hdr "$r" content-security-policy) == "$csp" ]]; then
    ok "www: /projects is projects.json, as JSON, revalidated each time"
else echo "$r"; fail "www: /projects"; fi

if [[ $(body "$(get /dark/proposals/a.html)") == *"<title>a proposal"* && $(body "$(get /light/)") == *"<title>home"* \
    && $(body "$(get /dark/assets/theme.css)") == dark && $(body "$(get /light/assets/theme.css)") == light \
    && $(code "$(get /dark)") == 404 && $(code "$(get /darkproposals/a.html)") == 404 ]]; then
    ok "www: /dark/ and /light/ the same pages, each with its theme's stylesheet (and /dark alone, or /darkx, not a copy)"
else fail "www: the theme copies"; fi

loc() { hdr "$(get "$1")" location; }
if [[ $(code "$(get '/?theme=light')") == 302 && $(loc '/?theme=light') == /light/ && $(loc '/proposals/a.html?theme=dark') == /dark/proposals/a.html \
    && $(loc '/dark/proposals/a.html?theme=system') == /proposals/a.html && $(loc '/light/proposals/a.html?theme=dark') == /dark/proposals/a.html \
    && $(loc '/dark?theme=system') == / && $(loc '//evil.example/x?theme=light') == /light/ && $(loc '/dark//evil.example?theme=system') == /dark//evil.example \
    && $(loc '/%5Cevil.example?theme=dark') == /dark/%5Cevil.example \
    && $(loc '/dark/proposals/b-%282022%29.html?theme=dark') == /dark/proposals/b-%282022%29.html \
    && $(loc '/proposals/b-%282022%29.html?theme=light') == /light/proposals/b-%282022%29.html ]]; then
    ok "www: the theme button's redirects, the page as it was asked for (%28 stays %28), never to another site (//host, /\\host; /dark//host and /%5Chost stay this site's paths, as nginx had them)"
else for p in '/?theme=light' '/proposals/a.html?theme=dark' '/dark/proposals/a.html?theme=system' '/dark?theme=system' '//evil.example/x?theme=light' '/dark//evil.example?theme=system' '/%5Cevil.example?theme=dark' '/dark/proposals/b-%282022%29.html?theme=dark'; do echo "$p -> $(loc "$p")"; done; fail "www: the theme redirects"; fi

r=$(get -H 'Range: bytes=0-3' /index.html) r2=$(docker exec "$name" curl -sS -o /dev/null -w '%{http_version}' --http2-prior-knowledge http://127.0.0.1:18080/ 2>&1 || true)
if [[ $(code "$r") == 200 && $(body "$r") == *"<title>home"* && $r2 != 2 ]]; then
    ok "www: no partial downloads (a Range is ignored) and no HTTP/2 (Go's HTTP/2 server code never reached)"
else echo "$r" | head -n 3; echo "http version: $r2"; fail "www: Range or HTTP/2"; fi

r=$(get /nope.html)
if [[ $(code "$r") == 404 && $(body "$r") == *"<title>not found"* && $(hdr "$r" content-security-policy) == "$csp" && -z $(hdr "$r" server) ]]; then
    ok "www: a missing page is the 404 page, with the same headers"
else echo "$r"; fail "www: the 404 page"; fi
r=$(get /proposals/)
if [[ $(code "$r") == 404 && $(body "$r") == *"<title>not found"* ]]; then ok "www: a folder without its page is the 404 page (no listing)"
else echo "$r" | head -n 5; fail "www: a folder without its page"; fi

r=$(onion_get /proposals/a.html)
if [[ $(code "$r") == 200 && $(body "$r") == *"<title>a proposal"* && $(hdr "$r" content-security-policy) == "$csp" \
    && -z $(hdr "$r" strict-transport-security) && -z $(hdr "$r" server) && $(hdr "$(onion_get '/?theme=dark')" location) == /dark/ ]]; then
    ok "www: the onion's socket, the same site and headers (no HSTS: it is http)"
else echo "$r"; fail "www: the onion's socket"; fi

exit "$status"

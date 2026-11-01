#!/usr/bin/env bash
# ccs-check against the Python it replaces (shadow mode, offline): each of ccs-receive's Python
# blocks and ccs-check's subcommand for it on the same files, their output the same, line for
# line. The files: addresses (real checksums, made with check_py's own Keccak) written every way
# the checks know (entities, groups, look-alike bytes, controls, data: images, JSON escapes...),
# then random mixes of those pieces. Needs python3 and a ccs-check (CCS_CHECK, else
# contrib/ccs-check/build.sh builds one). A test helper's Python (CI only, docs/python.md).
set -uo pipefail
here=$(dirname "$(readlink -f "$0")")
receive=$here/../contrib/ccs-receive
status=0
ok() { echo "ok   $1"; }
fail() { echo "FAIL $1"; status=1; }
t=$(mktemp -d)
trap '[[ ${KEEP:-} ]] || rm -rf "$t"' EXIT
if [[ -n ${CCS_CHECK:-} ]]; then check=$CCS_CHECK
else "$here/../contrib/ccs-check/build.sh" "$t/ccs-check" > /dev/null || exit 1; check=$t/ccs-check
fi
# block NAME: a Python block of ccs-receive, as it runs (scan_py and json_py after check_py)
block() { sed -n "/^$1='\$/,/^'\$/p; /^$1=\$check_py'\$/,/^'\$/p" "$receive" | sed '1d; $d'; }
block check_py > "$t/check.py"
for b in scan_py json_py; do { cat "$t/check.py"; block "$b"; } > "$t/$b.py"; done
[[ -s $t/scan_py.py && -s $t/json_py.py ]] || { echo "FAIL the Python blocks: not found in $receive"; exit 1; }

mkdir "$t/f"
python3 -I - "$t/check.py" "$t/f" <<'EOF' || fail "scan: making the files"
import json, os, random, sys
exec(open(sys.argv[1]).read())   # check_py: keccak, B58
out = sys.argv[2]
rnd = random.Random(1)
def enc(b):   # base58 as Monero has it (b58's inverse)
    s = ""
    for i in range(0, len(b), 8):
        blk = b[i:i + 8]; n = int.from_bytes(blk, "big"); k = {0: 0, 1: 2, 2: 3, 3: 5, 4: 6, 5: 7, 6: 9, 7: 10, 8: 11}[len(blk)]
        c = ""
        for _ in range(k): c = B58[n % 58] + c; n //= 58
        s += c
    return s
def address(net=18, integrated=False):
    d = bytes([net]) + bytes(rnd.randrange(256) for _ in range(64 + (8 if integrated else 0)))
    return enc(d + keccak(d)[:4])
A, I, T = address(), address(19, True), address(53)
bad = A[:-1] + ("2" if A[-1] != "2" else "3")   # the checksum off by a character
def groups(a, sep, n=4): return sep.join(a[i:i + n] for i in range(0, len(a), n))
def ents(a): return "".join(rnd.choice(["&#%d;" % ord(c), "&#x%x;" % ord(c), "&#%07d" % ord(c), c]) for c in a)
pieces = [A, I, T, bad, "x" + A + "x", A[:50], A[50:],
    groups(A, " "), groups(A, " - "), groups(A, "/"), groups(A, "    "), groups(A, "<>"), groups(A, "\n"), groups(A, "\t\t"),
    groups(A, "​"), groups(A, " "), groups(A, "\x00"), groups(A, "\x0b"), groups(A, "\x1c"), groups(A, "\x7f"),
    ents(A), "&amp;" + A, "&#99999999999999999999;", "&#x110000;", "&nbsp;", "&lt;" + A + "&gt;", "&#0;", "&#32;",
    A[:40] + "&#8203;" + A[40:], A[:40] + "­" + A[40:], A[:40] + "O" + A[41:], "0" * 95, "data:image/png;base64,iVBORw0KGgo=",
    "<img src=\"data:image/png;base64,QUJD\">", "monero:" + A, "<a href=\"monero:" + I + "\">", " AAAA" * 40, "4" * 106, A + I]
words = ["<p>", "</p>", " ", "\n", "text", "é", "⁦", "&", ";", "#", "<", ">", "=", "\"", "'", "\r\n"]
def mix(n): return "".join(rnd.choice(pieces if rnd.random() < 0.3 else words) for _ in range(n))
def w(name, s, enc="utf-8"):
    with open(os.path.join(out, name), "wb") as f: f.write(s.encode(enc, "surrogatepass") if isinstance(s, str) else s)
for i, p in enumerate(pieces):
    w("piece%02d.html" % i, "<p>" + p + "</p>")
    w("piece%02d.json" % i, json.dumps({"k": p, p[:20]: [p, 1]}))
    w("raw%02d.json" % i, "{\"k\": \"" + p.replace("\\", "") + "\"}", "latin-1" if i % 2 else "utf-8")
w("starts-space.html", "  \n<p>" + A + "</p>"); w("starts-text.html", "GIF89a" + A); w("empty.html", "")
w("bytes.html", b"<p>" + A[:30].encode() + b"\xe2\x80\x8b\xff\xfe" + A[30:].encode() + b"</p>")
w("dup.json", "{\"a\": \"%s\", \"a\": \"%s\"}" % (A, I)); w("escaped.json", "{\"a\": \"%s\"}" % "".join("\\u%04x" % ord(c) for c in A))
w("spaced.json", "{\"a\": \"%s\"}" % groups(A, "\\u0020")); w("zw.json", "{\"a\": \"%s\"}" % groups(A, "\\u200b"))
w("surrogate.json", "{\"a\": \"%s\\ud800%s\"}" % (A[:40], A[40:])); w("big.json", "[1e400, -0, 12345678901234567890123, \"%s\"]" % A)
for j, s in enumerate(["", " ", "{", "{}", "[]", "\"%s\"" % A, "{} {}", "{}}", "[1,]", "﻿{}", "{\"a\":1} x", "null", "[\"a\" \"b\"]", "{\"a\" 1}"]):
    w("edge%02d.json" % j, s)
w("nonutf8.json", b"{\"a\": \"\xff\"}")
for i in range(300):
    w("mix%03d.html" % i, ("<" if rnd.random() < 0.9 else "") + mix(rnd.randrange(1, 60)))
    w("mix%03d.json" % i, json.dumps([mix(rnd.randrange(1, 30)) for _ in range(rnd.randrange(1, 5))]))
EOF

# same NAME PYOUT GOOUT: the two outputs are the same, else the first lines that differ
same() {
    if cmp -s "$2" "$3"; then ok "$1"
    else fail "$1: Python and ccs-check differ:"; diff "$2" "$3" | head -8; fi
}
mapfile -t html < <(ls "$t"/f/*.html)
mapfile -t jsn < <(ls "$t"/f/*.json)
python3 -I "$t/scan_py.py" "${html[@]}" "${jsn[@]}" > "$t/py.scan" 2> "$t/py.err"
"$check" scan "${html[@]}" "${jsn[@]}" > "$t/go.scan"
same "scan: ${#html[@]} pages and ${#jsn[@]} JSON files as text, $(grep -c . "$t/py.scan") lines" "$t/py.scan" "$t/go.scan"
python3 -I "$t/json_py.py" "${jsn[@]}" > "$t/py.json" 2> "$t/py.err"
"$check" json "${jsn[@]}" > "$t/go.json"
same "json: ${#jsn[@]} JSON files, $(grep -c . "$t/py.json") lines" "$t/py.json" "$t/go.json"
# the budget: a few checksums, a file past it held back alone
CCS_GATE_KECCAK=3 python3 -I "$t/scan_py.py" "${html[@]}" > "$t/py.budget"
CCS_GATE_KECCAK=3 "$check" scan "${html[@]}" > "$t/go.budget"
same "scan, 3 checksums a file: $(grep -c 'too many' "$t/py.budget") files past it" "$t/py.budget" "$t/go.budget"
CCS_GATE_MAX=200 python3 -I "$t/scan_py.py" "${html[@]}" > "$t/py.max"
CCS_GATE_MAX=200 "$check" scan "${html[@]}" > "$t/go.max"
same "scan, files over 200 bytes not read: $(grep -c 'not read' "$t/py.max")" "$t/py.max" "$t/go.max"
# the NUL check (scan()'s inline Python)
nulpy=$(sed -n "/xargs -0 -r python3 -I -c 'import sys\$/,/print(f)'/p" "$receive" | sed "1s/.*-c 'import sys/import sys/; \$s/'.*//")
printf '%s\n' "$nulpy" > "$t/nul.py"
grep -q 'b"\\0" in h.read()' "$t/nul.py" || fail "the NUL check: not found in $receive"
python3 -I "$t/nul.py" "${html[@]}" "${jsn[@]}" > "$t/py.nul"
"$check" nul "${html[@]}" "${jsn[@]}" > "$t/go.nul"
same "nul: $(grep -c . "$t/py.nul") files with a NUL byte" "$t/py.nul" "$t/go.nul"
# pixels: PNGs of every format and filter pixels_py reads, each thing it refuses, and qrencode's
# with bytes changed at random; the same line (or none) for each
block pixels_py > "$t/pixels.py"
mkdir "$t/p"
qrencode -s 10 -o "$t/p/qrencode.png" "monero:4$(printf '%094d' 1 | tr 0 1)"
python3 -I - "$t/p" <<'EOF' || fail "pixels: making the PNGs"
import os, random, struct, sys, zlib
out = sys.argv[1]; rnd = random.Random(2)
def ch(t, c, crc=True): return struct.pack(">I", len(c)) + t + c + struct.pack(">I", zlib.crc32(t + c) if crc else 0)
def png(w, h, kind, depth, rows, extra=(), plte=None, trns=None, filters=(0,), il=0, z=None):
    ch_ = {0: 1, 3: 1, 2: 3, 4: 2, 6: 4}[kind]; stride = (w * ch_ * depth + 7) // 8
    raw = b"".join(bytes([filters[y % len(filters)]]) + rows(y, stride) for y in range(h))
    s = b"\x89PNG\r\n\x1a\n" + ch(b"IHDR", struct.pack(">IIBBBBB", w, h, depth, kind, 0, 0, il))
    if plte is not None: s += ch(b"PLTE", plte)
    if trns is not None: s += ch(b"tRNS", trns)
    for e in extra: s += e
    return s + ch(b"IDAT", z if z is not None else zlib.compress(raw)) + ch(b"IEND", b"")
noise = lambda y, n: bytes(rnd.randrange(256) for _ in range(n))
cases = {}
for kind, depth in ((0, 1), (0, 8), (3, 1), (3, 8), (2, 8), (6, 8), (0, 16), (4, 8), (2, 16)):
    for f in range(6):
        cases["k%dd%df%d" % (kind, depth, f)] = png(9, 7, kind, depth, noise, plte=bytes(range(30)) if kind == 3 else None, filters=(f,))
cases["filters-mixed"] = png(13, 11, 6, 8, noise, filters=(0, 1, 2, 3, 4))
cases["grey-trns"] = png(8, 8, 0, 8, lambda y, n: bytes([0, 7] * (n // 2)), trns=struct.pack(">H", 7))
cases["grey1-trns"] = png(8, 8, 0, 1, noise, trns=struct.pack(">H", 1))
cases["pal-trns"] = png(8, 8, 3, 8, lambda y, n: bytes(i % 4 for i in range(n)), plte=bytes(12), trns=b"\x00\x80")
cases["pal-short"] = png(8, 8, 3, 8, lambda y, n: bytes([9] * n), plte=bytes(12))
cases["pal-empty-trns"] = png(8, 8, 3, 8, lambda y, n: bytes(n), plte=bytes(3), trns=b"")
cases["rgb-trns"] = png(8, 8, 2, 8, noise, trns=b"\x00\x01\x00\x02\x00\x03")
cases["rgb-empty-trns"] = png(8, 8, 2, 8, noise, trns=b"")
cases["gama"] = png(8, 8, 0, 8, noise, extra=[ch(b"gAMA", struct.pack(">I", 45455))])
cases["phys"] = png(8, 8, 0, 8, noise, extra=[ch(b"pHYs", bytes(9))])
cases["actl"] = png(8, 8, 0, 8, noise, extra=[ch(b"acTL", bytes(8))])
cases["interlaced"] = png(8, 8, 0, 8, noise, il=1)
cases["wide"] = png(4097, 1, 0, 1, noise); cases["zero"] = png(0, 1, 0, 8, noise)
cases["badcrc"] = b"\x89PNG\r\n\x1a\n" + ch(b"IHDR", struct.pack(">IIBBBBB", 4, 4, 8, 0, 0, 0, 0), False) + ch(b"IDAT", zlib.compress(bytes(20)), False) + ch(b"IEND", b"", False)
good = zlib.compress(bytes(5 * 4))
cases["short-data"] = png(4, 4, 0, 8, lambda y, n: bytes(n), z=zlib.compress(bytes(15)))
cases["long-data"] = png(4, 4, 0, 8, lambda y, n: bytes(n), z=zlib.compress(bytes(25)))
cases["truncated-z"] = png(4, 4, 0, 8, lambda y, n: bytes(n), z=zlib.compress(bytes(20))[:-4])
cases["bad-adler"] = png(4, 4, 0, 8, lambda y, n: bytes(n), z=good[:-1] + bytes([good[-1] ^ 1]))
cases["trailing-z"] = png(4, 4, 0, 8, lambda y, n: bytes(n), z=good + b"junk")
cases["raw-deflate"] = png(4, 4, 0, 8, lambda y, n: bytes(n), z=zlib.compress(bytes(20))[2:])
cases["no-iend"] = png(4, 4, 0, 8, lambda y, n: bytes(n))[:-12]
cases["no-ihdr"] = b"\x89PNG\r\n\x1a\n" + ch(b"IEND", b"")
cases["two-ihdr"] = png(4, 4, 0, 8, lambda y, n: bytes(n), extra=[ch(b"IHDR", struct.pack(">IIBBBBB", 2, 2, 8, 0, 0, 0, 0))])
cases["split-idat"] = png(4, 4, 0, 8, lambda y, n: bytes(n), extra=[ch(b"IDAT", good[:5])], z=good[5:])
cases["not-png"] = b"GIF89a"; cases["empty"] = b""
for k, v in cases.items(): open(os.path.join(out, k + ".png"), "wb").write(v)
q = open(os.path.join(out, "qrencode.png"), "rb").read()
for i in range(400):
    b = bytearray(q)
    for _ in range(rnd.randrange(1, 4)): b[rnd.randrange(len(b))] = rnd.randrange(256)
    open(os.path.join(out, "mut%03d.png" % i), "wb").write(bytes(b))
EOF
: > "$t/py.pixels"; : > "$t/go.pixels"
for p in "$t"/p/*.png; do
    printf '%s %s\n' "${p##*/}" "$(python3 -I "$t/pixels.py" < "$p" 2> /dev/null)" >> "$t/py.pixels"
    printf '%s %s\n' "${p##*/}" "$("$check" pixels < "$p")" >> "$t/go.pixels"
done
same "pixels: $(find "$t/p" -name "*.png" | wc -l) PNGs, $(grep -c ' [0-9]* [0-9]* [0-9a-f]\{64\}$' "$t/py.pixels") read" "$t/py.pixels" "$t/go.pixels"

# pages: a site as ccs-front-bash makes it (FRONT_BASH: its checkout; its test fixtures, with a
# signed list and an onion), with its own design and, with DESIGN (ccs-front-hugo's public/), the
# real one; then each page changed at random, 40 times over; the same lines for every page
if [[ -z ${FRONT_BASH:-} ]]; then
    echo "skip pages: no FRONT_BASH (a ccs-front-bash checkout)"
    exit "$status"
fi
command -v jq qrencode > /dev/null || { fail "pages: needs jq and qrencode (ccs-front-bash's)"; exit 1; }
block pages_py > "$t/pages.py"
fx=$FRONT_BASH/tests/fixtures
mkdir -p "$t/sub" "$t/props" "$t/data"
# its data, its addresses base58 (the fixtures' 8000...001 has 0s, which an address can't have)
# and the proposals' links merge requests of the proposals repository (the fixtures'
# example.org/mr/N is no link the gate takes)
cp -R "$fx/data/." "$t/data/"
jq '.[1].proposals |= map(if ."donate-address" then ."donate-address" |= gsub("0"; "W") else . end)' "$fx/data/proposals.json" > "$t/data/proposals.json"
jq 'map(if .address then .address |= gsub("0"; "W") else . end)' "$fx/data/projects.json" > "$t/data/projects.json"
for f in "$t"/data/*.json; do
    sed -i 's#https://example\.org/mr/\([0-9]*\)#https://repo.getmonero.org/monero-project/ccs-proposals/-/merge_requests/\1#g' "$f"
done
main=9$(printf '%094d' 0 | tr 0 W)
{ echo "0 $main"; { jq -r '.[1].proposals[] | ."donate-address" // empty' "$t/data/proposals.json"
    jq -r '.[] | .address // empty' "$t/data/projects.json"; } | awk '!seen[$0]++ { print ++n, $0 }'
    echo "99 4$(printf '%094d' 7 | tr 0 1)"; } > "$t/sub/list.txt"
printf '%s\nsource https://example.org/x?a=1&b=2\nsource-text the post\n' "$(printf '%064d' 0 | tr 0 a)" > "$t/sub/list.txt.viewkey"
echo signature > "$t/sub/list.txt.asc"; echo key > "$t/sub/list.txt.key.asc"
printf 'sha256 %s\nkey 0123456789ABCDEF0123456789ABCDEF01234567\n' "$(sha256sum < "$t/sub/list.txt" | cut -d' ' -f1)" > "$t/sub/list.txt.pin"
onion=$(printf '%056d' 0 | tr 0 a).onion
hosts='repo.getmonero.org/monero-project/ccs-proposals gitlab.com/x/'
# the proposals as bodies() renders them: markdown.awk on each file, its images listed
cp "$fx"/proposals/*.md "$t/props/"
: > "$t/props/.images"
(cd "$t/props" && find . -maxdepth 1 -type f -name '*.md' -print0 | xargs -0 awk -v images="$t/props/.images" -f "$FRONT_BASH/lib/markdown.awk") > "$t/bodies.jsonl"
designs=("$fx/original")
[[ -n ${DESIGN:-} && -d $DESIGN/parts ]] && designs+=("$DESIGN")
for d in "${designs[@]}"; do
    name=$(basename "$(dirname "$d")")-$(basename "$d")
    CCS_ONION=$onion "$FRONT_BASH/ccs-front-bash.sh" "$d" "$t/data" "$t/props" "$t/site-$name" "$t/sub/list.txt" > /dev/null 2>&1 \
        || { fail "pages ($name): ccs-front-bash made no site"; continue; }
    python3 -I - "$t/site-$name" "$t/mut-$name" "$t/sub/list.txt" <<'EOF' || fail "pages ($name): changing the pages"
import os, random, shutil, sys
site, out, lst = sys.argv[1:4]
rnd = random.Random(3)
listed = [l.split()[1] for l in open(lst)]
unlisted = "4" + "".join(rnd.choice("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz") for _ in range(94))
pages = [os.path.relpath(os.path.join(r, f), site) for r, _, fs in os.walk(site) for f in fs if f.endswith(".html")]
bits = ["<", ">", "&", "&amp;", "&#39;", "\"", "'", "\n", " ", "x", "9", "é", "‮", "⁦", "<script>", "</div>",
        "8" * 90, "A" * 89, "€" * 91, "<!-- ccs:count fr -->", "https://repo.getmonero.org/monero-project/ccs-proposals/-/merge_requests/7",
        "https://evil.example/-/merge_requests/7", "data:image/png;base64,QUJD", "March 3, 2026", "–", " · funding since ", "+1.5 XMR pending"]
def mutate(t):
    for _ in range(rnd.randrange(1, 3)):
        op = rnd.randrange(6)
        i = rnd.randrange(len(t) + 1); j = min(len(t), i + rnd.randrange(1, 40))
        if op == 0: t = t[:i] + rnd.choice(bits) + t[i:]
        elif op == 1: t = t[:i] + t[j:]
        elif op == 2: t = t[:i] + rnd.choice(bits) + t[j:]
        elif op == 3 and any(a in t for a in listed):
            a = rnd.choice([a for a in listed if a in t]); t = t.replace(a, rnd.choice(listed + [unlisted]), rnd.choice([1, -1]))
        elif op == 4:   # a line twice (a card, a milestone)
            ls = t.split("\n"); k = rnd.randrange(len(ls)); ls.insert(k, ls[k]); t = "\n".join(ls)
        elif op == 5:   # a digit changed
            ds = [k for k, c in enumerate(t) if c.isdigit()]
            if ds: k = rnd.choice(ds); t = t[:k] + str((int(t[k]) + 1) % 10) + t[k + 1:]
    return t
# the other reasons, each once: the text, a milestone or a payout not the repository's, a page or
# proposal the design or the repository doesn't have, not UTF-8, an address not in the list
d = os.path.join(out, "special")
shutil.copytree(site, d)
P = lambda p: os.path.join(d, p)
def edit(p, f):
    t = open(P(p), encoding="utf-8").read(); open(P(p), "w", encoding="utf-8").write(f(t))
props = sorted(p for p in pages if p.startswith("proposals/"))
for k, p in enumerate(props):
    t = open(P(p), encoding="utf-8").read()
    if k % 4 == 0 and "<p>" in t:   # a word of its text
        edit(p, lambda t: t.replace("<p>", "<p>Not ", 1))
    elif k % 4 == 1 and "<!-- ccs:milestones -->" in t:
        edit(p, lambda t: t.replace("<!-- ccs:milestones -->\n", "<!-- ccs:milestones -->\n" + t.split("<!-- ccs:milestones -->\n")[1].split("\n")[0] + "\n", 1))
    elif k % 4 == 2 and "<!-- ccs:payouts -->" in t:
        edit(p, lambda t: t.replace("<!-- /ccs:payouts -->", "<!-- /ccs:payouts -->", 1).replace("<!-- ccs:payouts -->\n", "<!-- ccs:payouts -->\n" + t.split("<!-- ccs:payouts -->\n")[1].split("\n")[0] + "\n", 1))
    elif k % 4 == 3 and any(a in t for a in listed):
        a = next(a for a in listed if a in t); edit(p, lambda t: t.replace(a, unlisted))
shutil.copy(P(props[0]), P("proposals/no-such-proposal.html"))
os.makedirs(P("proposals/sub")); shutil.copy(P(props[0]), P("proposals/sub/x.html"))
shutil.copy(P("index.html"), P("random.html"))
os.makedirs(P("parts"), exist_ok=True); shutil.copy(P("index.html"), P("parts/donate.html"))
tags = [p for p in pages if p.startswith("explore/tag/")]
if tags: os.makedirs(P("explore/tag/zz-new")); shutil.copy(P(tags[0]), P("explore/tag/zz-new/index.html"))
open(P("bytes.html"), "wb").write(b"<p>\xff</p>")
os.makedirs(P("folder.html"))
for n in range(40):
    d = os.path.join(out, "%02d" % n)
    shutil.copytree(site, d)
    for p in pages:
        if rnd.random() < 0.7:
            f = os.path.join(d, p)
            t = open(f, encoding="utf-8").read()
            open(f, "w", encoding="utf-8").write(mutate(t))
EOF
    : > "$t/py.pages"; : > "$t/go.pages"
    # run SITE DESIGNS: both on every page of SITE, and on a name it doesn't have
    run() {
        (cd "$1" && { find . -name '*.html' -printf '%P\0'; printf 'no-such-file.html\0'; } | sort -z) > "$t/list"
        timeout 300 python3 -I "$t/pages.py" "$1" "$2" "$t/bodies.jsonl" "$t/sub/list.txt" "$t/sub/list.txt.viewkey" "$hosts" "$onion" < "$t/list" >> "$t/py.pages" 2>&1
        "$check" pages "$1" "$2" "$t/bodies.jsonl" "$t/sub/list.txt" "$t/sub/list.txt.viewkey" "$hosts" "$onion" < "$t/list" >> "$t/go.pages" 2>&1
    }
    run "$t/site-$name" "$d"
    for s in "$t/mut-$name"/*; do run "$s" "$d"; done
    # the special site again, with a design missing a part (the reason it gives), then with it
    # and the whole design after it (the second one passes what the first can't check)
    rm -rf "$t/broken" && cp -R "$d" "$t/broken" && rm "$t/broken/parts/payout.html"
    run "$t/mut-$name/special" "$t/broken"
    run "$t/mut-$name/special" "$t/broken:$d"
    n=$(grep -c . "$t/py.pages") good=$(grep -c "^$t/site-$name/.*=ok\$" "$t/py.pages")
    pages=$(find "$t/site-$name" -name '*.html' | wc -l)
    if ((good == pages)); then ok "pages ($name): every page ccs-front-bash made passes ($pages)"; else fail "pages ($name): $good of $pages made pass"; grep "^$t/site-$name/" "$t/py.pages" | grep -v '=ok$' | head -3; fi
    kinds=$(sed -n 's/^[^\t]*\t!//p' "$t/py.pages" | sed 's/ (.*//' | sort -u | wc -l)
    same "pages ($name): $pages pages, 40 times changed: $n lines, $(grep -c '=ok$' "$t/py.pages") ok, $kinds kinds of reason" "$t/py.pages" "$t/go.pages"
done
exit "$status"

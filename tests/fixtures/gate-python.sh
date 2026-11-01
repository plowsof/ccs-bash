# The Python checks the gate (contrib/ccs-receive) ran until ccs-check replaced them, as they
# were then: only tests/ccs-check.sh reads them, the reference each check of ccs-check must still
# give the answer of (CI only, never installed). Not run as a script.
check_py='
import os, re, sys, time
GROUPS = re.compile(r"[1-9A-HJ-NP-Za-km-z]+(?:[^1-9A-HJ-NP-Za-km-z0OIl<>\x01]{1,3}[1-9A-HJ-NP-Za-km-z]+)+")
class TooMany(Exception): pass
BUDGET, SECS = int(os.environ.get("CCS_GATE_KECCAK", 3000)), float(os.environ.get("CCS_GATE_SECS", 20))
spent = {"n": 0, "t": 0.0}
def start(): spent["n"], spent["t"] = 0, time.monotonic()
M = (1 << 64) - 1
RC = [1, 0x8082, 0x800000000000808a, 0x8000000080008000, 0x808b, 0x80000001, 0x8000000080008081,
      0x8000000000008009, 0x8a, 0x88, 0x80008009, 0x8000000a, 0x8000808b, 0x800000000000008b,
      0x8000000000008089, 0x8000000000008003, 0x8000000000008002, 0x8000000000000080, 0x800a,
      0x800000008000000a, 0x8000000080008081, 0x8000000000008080, 0x80000001, 0x8000000080008008]
ROT = [[0, 36, 3, 41, 18], [1, 44, 10, 45, 2], [62, 6, 43, 15, 61], [28, 55, 25, 21, 56], [27, 20, 39, 8, 14]]
def keccak(b):   # Keccak-256 as Monero has it (the original padding, not that of SHA3)
    b = bytearray(b) + b"\x01"
    while len(b) % 136: b += b"\x00"
    b[-1] |= 0x80
    s = [[0] * 5 for _ in range(5)]
    for o in range(0, len(b), 136):
        for i in range(17): s[i % 5][i // 5] ^= int.from_bytes(b[o + 8 * i:o + 8 * i + 8], "little")
        for r in RC:
            c = [s[x][0] ^ s[x][1] ^ s[x][2] ^ s[x][3] ^ s[x][4] for x in range(5)]
            d = [c[(x - 1) % 5] ^ (((c[(x + 1) % 5] << 1) | (c[(x + 1) % 5] >> 63)) & M) for x in range(5)]
            s = [[s[x][y] ^ d[x] for y in range(5)] for x in range(5)]
            t = [[0] * 5 for _ in range(5)]
            for x in range(5):
                for y in range(5):
                    v, n = s[x][y], ROT[x][y]
                    t[y][(2 * x + 3 * y) % 5] = ((v << n) | (v >> (64 - n))) & M if n else v
            s = [[t[x][y] ^ (~t[(x + 1) % 5][y] & t[(x + 2) % 5][y]) for y in range(5)] for x in range(5)]
            s[0][0] ^= r
    return b"".join(s[i % 5][i // 5].to_bytes(8, "little") for i in range(4))
B58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
SIZE = {0: 0, 2: 1, 3: 2, 5: 3, 6: 4, 7: 5, 9: 6, 10: 7, 11: 8}
def b58(s):   # base58 as Monero has it: blocks of 11 characters, 8 bytes
    out = b""
    for i in range(0, len(s), 11):
        n, k = 0, SIZE.get(len(s[i:i + 11]))
        for ch in s[i:i + 11]: n = n * 58 + B58.index(ch)
        if k is None or n >> (8 * k): return None
        out += n.to_bytes(k, "big")
    return out
NETS = (18, 19, 24, 25, 36, 42, 53, 54, 63)
seen_valid = {}
def valid(s):   # an address its checksum says is one, of a network Monero has (its first byte)
    if s[0] not in "45789AB" or (b58(s[:11]) or b"\x00")[0] not in NETS: return False
    if s in seen_valid: return seen_valid[s]
    d = b58(s)
    if d is None or d[0] not in NETS: return False
    spent["n"] += 1
    if spent["n"] > BUDGET or time.monotonic() - spent["t"] > SECS: raise TooMany()
    seen_valid[s] = keccak(d[:-4])[:4] == d[-4:]
    return seen_valid[s]
def grouped(t):   # the addresses written in groups in t (TooMany past the budget)
    out = set()
    for g in GROUPS.findall(re.sub(r"\s+", " ", t)):
        j = re.sub(r"[^1-9A-HJ-NP-Za-km-z]", "", g)
        out.update(j[i:i + n] for n in (95, 106) for i in range(len(j) - n + 1) if valid(j[i:i + n]))
    return out
'
scan_py=$check_py'
MAX = int(os.environ.get("CCS_GATE_MAX", 8 << 20))
ENT = re.compile(r"&#[0-9]+;?|&#[xX][0-9A-Fa-f]+;?|&[A-Za-z][A-Za-z0-9]*;")
NAMED = {"amp": 38, "lt": 60, "gt": 62, "quot": 34, "apos": 39}
QR = re.compile(r"data:image/png;base64,[A-Za-z0-9+/]+=*")
TOK = re.compile(r"[0-9A-Za-z]+")
def char(n):   # printable ASCII as itself, a space as one, anything else \x01 (read both ways)
    if 32 < n < 127: return chr(n)
    return " " if n in (9, 10, 12, 13, 32) else "\x01"
def entity(m):
    e = m.group(0)
    e = e[:-1] if e.endswith(";") else e
    if e[:3] in ("&#x", "&#X"): return char(int(e[3:], 16))
    if e[:2] == "&#": return char(int(e[2:]))
    return char(NAMED.get(e[1:], -1))
for f in sys.argv[1:]:
    if os.path.getsize(f) > MAX:
        print(f + "\t!over %d MB: not read" % (MAX >> 20)); continue
    with open(f, "rb") as h: d = h.read().decode("latin-1")
    out = set()
    if not re.match(r"[ \t\n\r]*[<\[{]", d):
        out.add(f + "\t!not text that starts as a page or JSON does (<, [ or {): a browser would show it as an image")
    d = ENT.sub(entity, re.sub(r"[\x80-\xff\x00-\x08\x0b\x0e-\x1f\x7f]", "\x01", d))
    # each data: image (the QR codes: pages() allows them nowhere else) to qrscan_py; not text
    for m in QR.finditer(d): print(f + "\t?qr\t" + m.group(0)[22:])
    d = QR.sub(" ", d)
    start()
    try:
        for t in (d.replace("\x01", ""), d.replace("\x01", " ")):
            out.update(f + "\t" + w for w in TOK.findall(t) if len(w) in (95, 106) and not re.search("[0OIl]", w))
            out.update(f + "\t" + a for a in grouped(t))
    except TooMany:
        out.add(f + "\t!too many runs that could be addresses to check")
    for l in sorted(out): print(l)
'
qrscan_py='
import ctypes as C, os, resource, sys
# 1 GB at most, for the decoders too: the size of a GIF frame is only known once giflib has
# allocated and decoded it, and a small file can claim (and fill) one of 65535x65535
resource.setrlimit(resource.RLIMIT_AS, (1 << 30, 1 << 30))
L = lambda n: C.CDLL(n)
if sys.argv[1:] == ["--check"]:
    for n in ("libzbar.so.0", "libpng16.so.16", "libturbojpeg.so.0", "libgif.so.7"): L(n)
    sys.exit(0)
kind, path, inverted = sys.argv[1], sys.argv[2], sys.argv[3:] == ["inverted"]
MAXPX = 40000000
class Unchecked(Exception): pass
data = open(path, "rb").read((8 << 20) + 1)
if len(data) > 8 << 20: sys.exit(2)
def fits(w, h):   # at most MAXPX, else Unchecked (an image too large is not "no code")
    if w * h > MAXPX: raise Unchecked()
    return w > 0 and h > 0
if os.environ.get("CCS_GATE_SCANLOG"):
    with open(os.environ["CCS_GATE_SCANLOG"], "a") as f: f.write("".join(chr(b) if 32 < b < 127 else "%03o" % b for b in data[:4]) + " " + kind + "\n")
P = C.POINTER
def png():
    lib = L("libpng16.so.16")
    class Img(C.Structure):
        _fields_ = [("opaque", C.c_void_p), ("version", C.c_uint32), ("width", C.c_uint32), ("height", C.c_uint32), ("format", C.c_uint32),
                    ("flags", C.c_uint32), ("colormap_entries", C.c_uint32), ("warning_or_error", C.c_uint32), ("message", C.c_char * 64)]
    lib.png_image_begin_read_from_memory.argtypes = [P(Img), C.c_char_p, C.c_size_t]
    lib.png_image_finish_read.argtypes = [P(Img), C.c_void_p, C.c_void_p, C.c_int32, C.c_void_p]
    lib.png_image_free.argtypes = [P(Img)]
    im = Img(version=1)   # PNG_IMAGE_VERSION
    if not lib.png_image_begin_read_from_memory(C.byref(im), data, len(data)): return []
    w, h = im.width, im.height
    if not fits(w, h): lib.png_image_free(C.byref(im)); return []
    im.format = 0   # PNG_FORMAT_GRAY: any alpha laid on white, as a browser on a white page
    buf, white = C.create_string_buffer(w * h), (C.c_ubyte * 3)(255, 255, 255)
    if not lib.png_image_finish_read(C.byref(im), white, buf, w, None): return []
    return [(w, h, buf.raw)]
def jpeg():
    lib = L("libturbojpeg.so.0")
    lib.tjInitDecompress.restype = C.c_void_p
    lib.tjDecompressHeader3.argtypes = [C.c_void_p, C.c_char_p, C.c_ulong] + [P(C.c_int)] * 4
    lib.tjDecompress2.argtypes = [C.c_void_p, C.c_char_p, C.c_ulong, C.c_void_p, C.c_int, C.c_int, C.c_int, C.c_int, C.c_int]
    lib.tjDestroy.argtypes = [C.c_void_p]
    t = lib.tjInitDecompress(); w, h, ss, cs = C.c_int(), C.c_int(), C.c_int(), C.c_int()
    try:
        if lib.tjDecompressHeader3(t, data, len(data), C.byref(w), C.byref(h), C.byref(ss), C.byref(cs)) != 0: return []
        if not fits(w.value, h.value): return []
        buf = C.create_string_buffer(w.value * h.value)
        if lib.tjDecompress2(t, data, len(data), buf, w.value, 0, h.value, 6, 0) != 0: return []   # TJPF_GRAY
        return [(w.value, h.value, buf.raw)]
    finally: lib.tjDestroy(t)
def gif():
    lib = L("libgif.so.7")
    class Color(C.Structure): _fields_ = [("r", C.c_ubyte), ("g", C.c_ubyte), ("b", C.c_ubyte)]
    class Map(C.Structure): _fields_ = [("count", C.c_int), ("bits", C.c_int), ("sort", C.c_bool), ("colors", P(Color))]
    class Desc(C.Structure): _fields_ = [("left", C.c_int), ("top", C.c_int), ("width", C.c_int), ("height", C.c_int), ("interlace", C.c_bool), ("map", P(Map))]
    class Saved(C.Structure): _fields_ = [("desc", Desc), ("raster", P(C.c_ubyte)), ("next", C.c_int), ("ext", C.c_void_p)]
    class Gif(C.Structure):
        _fields_ = [("swidth", C.c_int), ("sheight", C.c_int), ("res", C.c_int), ("bg", C.c_int), ("aspect", C.c_ubyte), ("map", P(Map)),
                    ("count", C.c_int), ("image", Desc), ("saved", P(Saved)), ("next", C.c_int), ("ext", C.c_void_p), ("error", C.c_int),
                    ("user", C.c_void_p), ("private", C.c_void_p)]
    lib.DGifOpenFileName.argtypes = [C.c_char_p, P(C.c_int)]; lib.DGifOpenFileName.restype = P(Gif)
    lib.DGifSlurp.argtypes = [P(Gif)]; lib.DGifCloseFile.argtypes = [P(Gif), P(C.c_int)]
    err = C.c_int(); g = lib.DGifOpenFileName(os.fsencode(path), C.byref(err))
    if not g: return []
    try:
        if not fits(g.contents.swidth, g.contents.sheight): return []
        if lib.DGifSlurp(g) != 1:
            if g.contents.error == 109: raise Unchecked()   # D_GIF_ERR_NOT_ENOUGH_MEM
            return []
        out = []
        for i in range(min(g.contents.count, 100)):
            s = g.contents.saved[i]; w, h = s.desc.width, s.desc.height
            m = s.desc.map or g.contents.map
            if not (m and s.raster and fits(w, h)): continue
            grey = bytes((c.r * 299 + c.g * 587 + c.b * 114) // 1000 for c in m.contents.colors[:m.contents.count])
            out.append((w, h, C.string_at(s.raster, w * h).translate(grey + b"\xff" * (256 - len(grey)))))
        return out
    finally: lib.DGifCloseFile(g, C.byref(err))
Z = L("libzbar.so.0")
Z.zbar_image_scanner_create.restype = Z.zbar_image_create.restype = C.c_void_p
Z.zbar_image_set_format.argtypes = [C.c_void_p, C.c_ulong]
Z.zbar_image_set_size.argtypes = [C.c_void_p, C.c_uint, C.c_uint]
Z.zbar_image_set_data.argtypes = [C.c_void_p, C.c_void_p, C.c_ulong, C.c_void_p]
Z.zbar_scan_image.argtypes = [C.c_void_p, C.c_void_p]
Z.zbar_image_first_symbol.argtypes = Z.zbar_symbol_next.argtypes = Z.zbar_symbol_get_data.argtypes = Z.zbar_symbol_get_data_length.argtypes = [C.c_void_p]
Z.zbar_image_first_symbol.restype = Z.zbar_symbol_next.restype = Z.zbar_symbol_get_data.restype = C.c_void_p
Z.zbar_image_destroy.argtypes = [C.c_void_p]
scanner = Z.zbar_image_scanner_create()
# QR codes only: every kind of code off (symbology 0, all of them), then QR (64) on, so none of
# the readers for the others (EAN, Code 128, DataBar, PDF417...) ever sees these bytes
Z.zbar_image_scanner_set_config.argtypes = [C.c_void_p, C.c_int, C.c_int, C.c_int]
if Z.zbar_image_scanner_set_config(scanner, 0, 0, 0) or Z.zbar_image_scanner_set_config(scanner, 64, 0, 1): sys.exit(1)
def scan(w, h, grey):
    img, buf = Z.zbar_image_create(), C.create_string_buffer(grey, len(grey))
    Z.zbar_image_set_format(img, 0x30303859)   # Y800: 8-bit grey
    Z.zbar_image_set_size(img, w, h); Z.zbar_image_set_data(img, buf, len(grey), None)
    Z.zbar_scan_image(scanner, img)
    out, s = [], Z.zbar_image_first_symbol(img)
    while s: out.append(C.string_at(Z.zbar_symbol_get_data(s), Z.zbar_symbol_get_data_length(s))); s = Z.zbar_symbol_next(s)
    Z.zbar_image_destroy(img)
    return out
found = []
try: frames = {"png": png, "jpeg": jpeg, "gif": gif}[kind]()
except (Unchecked, MemoryError): sys.exit(2)
for w, h, grey in frames:
    got = scan(w, h, grey)
    if not got and inverted: got = scan(w, h, grey.translate(bytes(range(255, -1, -1))))
    found += got
for t in found: sys.stdout.buffer.write(t + b"\n")
sys.exit(0 if found else 1)
'
pixels_py='
import hashlib, struct, sys, zlib
d = sys.stdin.buffer.read(4 << 20)
assert d[:8] == b"\x89PNG\r\n\x1a\n"
i, idat, plte, trns, hdr = 8, b"", b"", None, None
while True:
    n, t = struct.unpack(">I4s", d[i:i + 8]); c = d[i + 8:i + 8 + n]; i += 12 + n
    assert len(c) == n and t in (b"IHDR", b"PLTE", b"tRNS", b"pHYs", b"IDAT", b"IEND")
    if t == b"IHDR": hdr = struct.unpack(">IIBBBBB", c)
    elif t == b"PLTE": plte = c
    elif t == b"tRNS": trns = c
    elif t == b"IDAT": idat += c
    elif t == b"IEND": break
w, h, depth, kind, _, _, interlace = hdr
assert 0 < w <= 4096 and 0 < h <= 4096 and interlace == 0 and (kind, depth) in ((0, 1), (0, 8), (3, 1), (3, 8), (2, 8), (6, 8))
ch = {0: 1, 3: 1, 2: 3, 6: 4}[kind]
stride = (w * ch * depth + 7) // 8; bpp = max(1, ch * depth // 8)
z = zlib.decompressobj(); raw = z.decompress(idat, h * (stride + 1) + 1)
assert len(raw) == h * (stride + 1)
out, prev = bytearray(), bytearray(stride)
for y in range(h):
    f, row = raw[y * (stride + 1)], bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
    for x in range(stride):
        a = row[x - bpp] if x >= bpp else 0; b = prev[x]; c = prev[x - bpp] if x >= bpp else 0
        if f == 1: row[x] = (row[x] + a) & 255
        elif f == 2: row[x] = (row[x] + b) & 255
        elif f == 3: row[x] = (row[x] + (a + b) // 2) & 255
        elif f == 4:
            p = a + b - c; pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
            row[x] = (row[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        else: assert f == 0
    prev = row
    for x in range(w):
        if depth == 1: v = (row[x >> 3] >> (7 - (x & 7))) & 1
        else: v = row[x * ch]
        if kind == 3:
            assert 3 * v + 3 <= len(plte)
            out += plte[3 * v:3 * v + 3] + bytes([trns[v] if trns and v < len(trns) else 255])
        elif kind == 0:
            g = v * 255 if depth == 1 else v
            out += bytes([g, g, g, 0 if trns and len(trns) == 2 and struct.unpack(">H", trns)[0] == v else 255])
        elif kind == 2:
            assert trns is None
            out += row[x * 3:x * 3 + 3] + b"\xff"
        else: out += row[x * 4:x * 4 + 4]
print(w, h, hashlib.sha256(out).hexdigest())
'
json_py=$check_py'
import json
for f in sys.argv[1:]:
    seen = []
    def pairs(p):   # every pair as it is read, the same key twice too; what is left to walk: none
        for k, v in p: seen.append(k); walk(v)
        return {}
    def walk(v):
        if isinstance(v, str): seen.append(v)
        elif isinstance(v, list):
            for x in v: walk(x)
        elif isinstance(v, dict):
            for x in v.values(): walk(x)
    try:
        with open(f, "rb") as h: walk(json.loads(h.read(16 << 20).decode("utf-8"), object_pairs_hook=pairs))
    except Exception:
        print(f + "\t!not JSON (UTF-8) that reads"); continue
    out = set()
    start()
    try:
        for s in seen:
            s = re.sub(r"[\t\n\f\r]", " ", s); s = re.sub(r"[\x00-\x1f\x7f]", "", s)
            for t in (re.sub(r"[^\x00-\x7f]", "", s), re.sub(r"[^\x00-\x7f]", " ", s)):
                out.update(w for w in re.findall(r"[0-9A-Za-z]+", t) if len(w) in (95, 106) and not re.search(r"[0OIl]", w))
                out.update(grouped(t))
    except TooMany:
        out.add("!too many runs that could be addresses to check")
    for a in sorted(out): print(f + "\t" + a)
'
pages_py='
import json, os, re, sys

site, designs, bodies, lst, viewkey, hosts, onion = sys.argv[1:8]
MAX = int(os.environ.get("CCS_GATE_MAX", 8 << 20))   # a page larger is not read (nor checked)
B58 = "[1-9A-HJ-NP-Za-km-z]"
# escaped text (as ccs-bash and markdown.awk escape it): no markup, no bidi controls (they can
# show the halves of an address in another order than written), at most 1000 characters, and no
# run of 90 characters each base58 or not ASCII: an address padded or split by invisible
# characters, or drawn with look-alikes (a mathematical or fullwidth 9, a Cyrillic A). Any
# character that is not ASCII counts, not only letters: Unicode tables differ between Python and
# the jq that shortens idea titles by the same rule (gitlab.sh), and must agree with it. An
# address in groups ("4A9b xZq3", "4A9b - xZq3", "4A9b/xZq3"): scan_py, by its checksum
# (gitlab.sh shortens every such run that holds one, with the same separators, so the two agree)
RUN = "(?:" + B58 + "|[^\\x00-\\x7f])"
TEXT = "(?:(?!" + RUN + "{90})(?:[^<>\"\x27&\\x00-\\x1f\\x7f\\u202a-\\u202e\\u2066-\\u2069]|&(?:amp|lt|gt|quot|#39|apos);)){0,1000}"
# a milestone or payout: anything escaped, compared afterwards with the repository
LOOSE = "[^<>\\n]{0,4000}"
NAME = "(?:[^\"<>/&\\n]|&(?:amp|lt|gt|quot|#39|apos);){1,300}"
NUM = "[0-9]{1,30}"
XMR = "[0-9]{1,30}(?:\\.[0-9]{1,30})?"
DATE = "(?:(?:January|February|March|April|May|June|July|August|September|October|November|December) [1-9][0-9]?, [0-9]{4})?"   # as site.jq writes them
# a link to a proposal: under one of HOSTS (the proposals repository, by its path), its merge
# request (GitLab, old or new form) or pull request (Forgejo), and nothing else: not an issue or a
# file anyone could write in "Comments and updates"
MR = "(?:/-/merge_requests/|/merge_requests/|/pulls/)[0-9]{1,10}"
LINK = ("https://(?:" + "|".join(re.escape(h.strip("/")) for h in hosts.split()) + ")" + MR) if hosts.split() else "(?!)"

def read(p):
    with open(p, "rb") as f: return f.read().decode("utf-8")
def part(t): return t[:-1] if t.endswith("\n") else t      # as jq rtrimstr("\n")
def strip(t): return t.rstrip("\n")                         # $(cat FILE)
def prefix(depth): return "./" if depth == 0 else "../" * depth
def rel(t, depth):   # as relative_links in ccs-front-bash, a line at a time as sed
    return re.sub("((?:href|src)=\")/([^/\\n])", lambda m: m.group(1) + prefix(depth) + m.group(2), t)
def esc(s):          # as jq @html (1.6 writes \x27 as &#39;, later ones as &apos;: same() reads both)
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\x27", "&#39;").replace("\"", "&quot;")
def same(a, b): return a.replace("&apos;", "&#39;") == b.replace("&apos;", "&#39;")
def put(t, v):       # as common.jq fill: every {{slot}}, in one pass
    return re.sub("\\{\\{([a-z_]+)\\}\\}", lambda m: v[m.group(1)], t)

# the signed list: its addresses (the only ones a donation box may show), its main address and
# fingerprint, as check_addresses shows them on Verify
rows = [l.split() for l in read(lst).splitlines()]
listed = {r[1] for r in rows if len(r) >= 2}
main = next(r[1] for r in rows if r[:1] == ["0"])
fpr = next(l[4:].strip() for l in read(lst + ".pin").splitlines() if l.startswith("key "))
fpr = re.sub("^((.{4} ){5})", "\\1 ", re.sub(" $", "", re.sub("(.{4})", "\\1 ", fpr)))
net = " --testnet" if main[0] in "9A" else " --stagenet" if main[0] in "57" else ""

# each proposal as markdown.awk renders it, from each commit (any of them will do): its text, and
# its milestones and payouts (as JSON)
md = {}
for f in bodies.split(":"):
    if f and os.path.exists(f):
        for l in read(f).splitlines():
            if l:
                j = json.loads(l)
                md.setdefault(j["file"], set()).add((j["body"].replace("\x01", ""), json.dumps(j.get("milestones", [])), json.dumps(j.get("payouts", []))))

class Design:
    def __init__(self, d):
        self.d = d
        self.p = {f[:-5]: read(os.path.join(d, "parts", f)) for f in os.listdir(os.path.join(d, "parts")) if f.endswith(".html")}
    # the regex of a part: its literal text as it is, each {{slot}} by SLOTS (name: regex); a slot
    # in SAME is one value however often the part has it (a group, then a backreference)
    def fill(self, text, slots, same=()):
        out, i, seen = "", 0, set()
        for m in re.finditer("\\{\\{([a-z_]+)\\}\\}", text):
            k = m.group(1)
            if k not in slots: raise KeyError(k)
            if k in same and k in seen: rx = "(?P=" + k + ")"
            elif k in same: rx = "(?P<" + k + ">" + slots[k] + ")"; seen.add(k)
            else: rx = "(?:" + slots[k] + ")"
            out += re.escape(text[i:m.start()]) + rx; i = m.end()
        return out + re.escape(text[i:])
    def card(self, stage, depth, tagpage):
        c = part(self.p["card-" + stage])
        if tagpage: c = c.replace("=\"../", "=\"../../../")
        c = rel(c, depth)
        url = "#|" + re.escape(prefix(depth)) + "proposals/" + NAME + "\\.html|" + LINK
        seg = "(?:" + re.escape(part(self.p["segment-done"])) + "|" + re.escape(part(self.p["segment-todo"])) + ")*"
        label = self.fill(part(self.p["label"]), {"tag": TEXT, "color": "tag-[0-7]"})
        return self.fill(c, {"url": url, "name": TEXT, "author": TEXT, "date": DATE,
            "funding_note": "(?: · funding since " + DATE + ")?", "funding_date": DATE, "contributors": NUM, "amount": XMR, "raised": XMR,
            "percentage": NUM, "done": NUM, "milestones": NUM, "pending_note": "(?: (?:· )?\\+?" + XMR + " XMR pending)?",
            "upvotes": NUM + "|–", "downvotes": NUM + "|–", "segments": seg, "tags": "(?:" + label + ")*"})
    def nav(self, depth):
        href = re.escape(prefix(depth)) + "explore/tag/[A-Za-z0-9%._~-]+/"
        f = self.fill(part(self.p["filter"]), {"tag": TEXT, "color": "tag-[0-7]", "href": href, "count": NUM, "active": "(?: active)?"})
        return "(?:" + self.fill(part(self.p["filters"]), {"filters": "(?:" + f + ")*"}) + ")?"
    def verify(self):
        f = strip(self.p["verify"])
        # without the view key file, nothing for the slots that show it (ccs-front-bash needs it too)
        slots = {"address": re.escape(main), "fingerprint": re.escape(fpr), "network": re.escape(net),
                 "viewkey": "(?!)", "wallet_source": "(?!)"}
        if viewkey:
            v = read(viewkey).splitlines()
            src = next((l.split(None, 1)[1].strip() for l in v if l.startswith("source ")), "")
            txt = next((l.split(None, 1)[1].strip() for l in v if l.startswith("source-text ")), "").replace("\x27", "&#39;")
            slots["viewkey"] = re.escape(v[0].replace(" ", ""))
            slots["wallet_source"] = re.escape("<a href=\"" + src.replace("&", "&amp;") + "\">" + (txt or "where they were published") + "</a>") if src else "published by this site"
        return self.fill(f, slots)
    # the milestones and payouts of a proposal (JSON from markdown.awk) as pages.jq makes them
    def milestones(self, ms, depth):
        r = "\n".join(put(part(self.p["milestone-done" if x[2] != "" else "milestone-todo"]), {"name": esc(x[0]), "funds": esc(x[1]), "date": esc(x[2])}) for x in json.loads(ms))
        return rel(r or part(self.p["no-milestones"]), depth)
    def payouts(self, ps, depth):
        r = "\n".join(put(part(self.p["payout"]), {"date": esc(x[0]), "amount": esc(x[1])}) for x in json.loads(ps))
        return rel(r or part(self.p["no-payouts"]), depth)
    # what region NAME may hold on a page DEPTH folders down; on a proposal page (BODY) the
    # milestones and payouts are kept (groups), to compare with the repository after
    def region(self, name, depth, tagpage, body=False):
        kind, _, arg = name.partition(" ")
        if kind in ("count", "number"): return NUM
        if kind == "title": return TEXT
        if kind == "filters": return self.nav(depth)
        if kind == "verify": return self.verify()
        # the onion line of the footer: nothing, or the onion part of the design with the onion
        # address of this site (ONION, /etc/ccs-gate/onion), never another: a backend cannot send
        # visitors to an onion of its choosing
        if kind == "onion":
            if not onion or "onion" not in self.p: return ""
            return "(?:" + re.escape(put(part(self.p["onion"]), {"onion": onion})) + ")?"
        if kind == "list":
            c = self.card(arg, depth, tagpage)
            return "(?:" + c + "(?:\\n" + c + ")*|" + re.escape(part(self.p["empty"])) + ")?"
        # the donation box: one address, in its text, its monero: link and its QR code (checked after);
        # or, a Funding Required proposal at its goal, the donate-funded part of the design in its place
        # ("Funded", no address), only with its bar at 100. The backend writes the bar (the
        # amounts never were checked here): one that says 100 can take a box away, never change it
        if kind in ("donate", "funded"):
            r = self.fill(part(self.p[kind]), self.slots(depth), ("address", "qr"))
            if kind == "donate" and "donate-funded" in self.p:
                r = "(?:" + r + "|" + self.fill(part(self.p["donate-funded"]), dict(self.slots(depth), percentage="100")) + ")"
            return r
        t = LOOSE if body else TEXT
        if kind == "milestones":
            m = "(?:" + self.fill(part(self.p["milestone-done"]), {"name": t, "funds": t, "date": t}) + "|" \
                + self.fill(part(self.p["milestone-todo"]), {"name": t, "funds": t}) + ")"
            r = m + "(?:\\n" + m + ")*|" + re.escape(part(self.p["no-milestones"]))
        elif kind == "payouts":
            m = self.fill(part(self.p["payout"]), {"amount": t, "date": t})
            r = m + "(?:\\n" + m + ")*|" + re.escape(part(self.p["no-payouts"]))
        else: raise KeyError(name)
        return "(?P<" + kind + ">" + r + ")" if body else r
    def slots(self, depth, body=None):
        seg = "(?:" + re.escape(part(self.p["segment-done"])) + "|" + re.escape(part(self.p["segment-todo"])) + ")*"
        href = re.escape(prefix(depth)) + "explore/tag/[A-Za-z0-9%._~-]+/"
        s = {"name": TEXT, "author": TEXT, "date": DATE, "funding_note": "(?: · funding since " + DATE + ")?", "funding_date": DATE,
             "contributors": NUM, "amount": XMR, "raised": XMR, "percentage": NUM, "done": NUM, "milestones": NUM,
             "pending_note": "(?: (?:· )?\\+?" + XMR + " XMR pending)?", "gitlab_url": "#|" + LINK, "segments": seg,
             "needed_note": "(?: " + XMR + " XMR would fund it 100%!)?",
             "address": B58 + "{95}", "qr": "data:image/png;base64,[A-Za-z0-9+/]+=*",
             "verify_link": re.escape(strip(self.p["verify-link"])), "milestones_list": "", "payouts_list": "",
             "tag_links": "(?:" + self.fill(part(self.p["label-link"]), {"tag": TEXT, "color": "tag-[0-7]", "href": href}) + ")*"}
        if body: s["body"] = "(?P<body>.*?)"   # compared with the repository after (one regex for every page)
        return s
    # the regex of a page: its literal text, the regions as above, the slots (on a proposal page)
    def page(self, text, depth, tagpage, body=False):
        out, i = [], 0
        for m in re.finditer("<!-- ccs:([a-z]+(?: [a-z]+)?) -->", text):
            end = "<!-- /ccs:" + m.group(1) + " -->"
            j = text.index(end, m.end())
            out.append(self.fill(rel(text[i:m.start()], depth), self.slots(depth, body)) if body else re.escape(rel(text[i:m.start()], depth)))
            out.append(re.escape(m.group(0)) + "\\n*(?:" + self.region(m.group(1), depth, tagpage, body) + ")\\n*" + re.escape(end))
            i = j + len(end)
        rest = rel(text[i:], depth)
        out.append(self.fill(rest, self.slots(depth, body)) if body else re.escape(rest))
        return out

cache, diag = {}, [10]
def compiled(d, key, text, depth, tagpage, body=False):
    k = (d.d, key, depth, tagpage)
    if k not in cache:
        segs = d.page(text, depth, tagpage, body)
        cache[k] = (re.compile("".join(segs), re.S), segs)
    return cache[k]

# check: (None, donation box or None) if the page passes, else (reason, None)
def check(rp, got, d):
    depth, want = rp.count("/"), None
    if rp.startswith("proposals/"):
        name = rp[len("proposals/"):-len(".html")]
        if "/" in name: return "a page the design does not have", None
        if name not in md: return "a proposal page with no proposal (" + name + ".md) in the proposals repository", None
        want = md[name]
        # pages.jq prints the page, jq -r a newline after it, which the split keeps
        tries = [compiled(d, "proposal-" + s, d.p["proposal-" + s] + "\n", depth, False, True) for s in ("fr", "wip", "cp")]
    elif re.match("explore/tag/[^/]+/index\\.html$", rp):
        tries = [compiled(d, "tag", read(os.path.join(d.d, "explore/tag/example/index.html")), depth, True)]
    elif not rp.startswith(("parts/", "explore/tag/")) and os.path.isfile(os.path.join(d.d, rp)):
        tries = [compiled(d, rp, read(os.path.join(d.d, rp)), depth, False)]
    else: return "a page the design does not have", None
    best, why = 0, "not a page of the design as ccs-front-bash fills it"
    for rx, segs in tries:
        m = rx.fullmatch(got)
        if m and want is not None:
            g = m.groupdict()
            if not any(g["body"] == rel(b, depth) and (g.get("milestones") is None or same(g["milestones"], d.milestones(ms, depth)))
                       and (g.get("payouts") is None or same(g["payouts"], d.payouts(ps, depth))) for b, ms, ps in want):
                # the page of the design, but another text than the proposal has in the repository
                best, why = m.start("body"), "not the text, milestones or payouts of its proposal as the proposals repository has them"; continue
        if m:
            a = m.groupdict().get("address")
            if a is None: return None, None
            if a not in listed: return "a donation box with an address that is not in the signed list (" + a + ")", None
            return None, (a, m.group("qr").split(",", 1)[1])   # its base64
        if diag[0] <= 0: continue
        for k in range(len(segs), 0, -1):   # how far it is the design, for the reason (10 pages)
            m = re.match("".join(segs[:k]), got, re.S)
            if m: best = max(best, m.end()); break
    diag[0] -= 1
    return why + (" (it differs at character %d: %s)" % (best, json.dumps(got[best:best + 60])) if diag[0] >= 0 else ""), None

ds = [Design(d) for d in designs.split(":") if d]
for rp in sys.stdin.read().split("\0"):
    if not rp: continue
    p = os.path.join(site, rp)
    try:
        if os.path.getsize(p) > MAX: print(p + "\t!a page over %d MB" % (MAX >> 20)); continue
        got = read(p)
    except Exception: print(p + "\t!a page that is not UTF-8"); continue
    why = box = None
    for d in ds:
        try: why, box = check(rp, got, d)
        except KeyError as e: why = "the design has no part or slot " + str(e)
        except Exception as e: why = "a page that could not be checked (" + type(e).__name__ + ")"
        if why is None: break
    if why: print(p + "\t!" + why); continue
    if box: print(p + "\t=box\t" + box[0] + "\t" + box[1])
    print(p + "\t=ok")
'
nul_py='import sys
for f in sys.argv[1:]:
    with open(f, "rb") as h:
        if b"\0" in h.read(): print(f)
'

# Plan: the gate's checks in Go, Python retired

Status: proposed (2026-11-01). Today Python runs only in the web server's gate,
`contrib/ccs-receive` (see [python.md](python.md)). This plan replaces it with one static Go
binary, `ccs-check`, built by StageX like everything else, and then removes Python, libffi and
the C image libraries from the gate's image.

**Why.** The gate's riskiest code is not Python but the C libraries it calls through ctypes
(libzbar, libpng, libjpeg, giflib) to decode images a backend sends: a bug there can run code
as `ccs-data`, which can write the live site. Go decodes PNG, JPEG and GIF in memory-safe code,
its regexes run in linear time, and the result is one reproducible file with no interpreter.
**What it isn't:** free. A new language to review, a third-party QR decoder to vet, and a
rewrite of the code that keeps donation addresses honest, so it is done beside the old checks
until they agree.

## What moves

| Today (Python in ccs-receive) | Lines | ccs-check | Go |
|---|---|---|---|
| `json_py`: projects.json reads as JSON | 27 | `ccs-check json FILE...` | `encoding/json` |
| `check_py`: base58 and Keccak-256 checksums | 58 | shared package `addr` | `golang.org/x/crypto/sha3` (`NewLegacyKeccak256`) |
| `scan_py`: addresses, also spaced, split, look-alike | 33 | `ccs-check scan FILE...` | `golang.org/x/text/unicode/norm` (NFKC) |
| `qrscan_py`: QR codes in images (libzbar) | 99 | `ccs-check qr FILE...` | `image/png`, `image/jpeg`, `image/gif` + a QR decoder (to choose, task 2) |
| `pixels_py`: a QR image is qrencode's, pixel for pixel | 45 | `ccs-check pixels` or gone (task 9) | `image` |
| `pages_py`: pages are the design's, filled with its parts | 223 | `ccs-check pages ...` | `regexp` (RE2: no backreferences, so region by region) |
| `rrsync`: the push account may only rsync into staging | — | `ccs-check rrsync` or a shell version | — |

`feed_awk` and everything else in ccs-receive stay as they are (bash and awk). The command line
of each subcommand and its output lines (`file<TAB>ok`, `file<TAB>!reason`, `file<TAB>address`)
are exactly the Python blocks', so ccs-receive changes one line per check.

## Tasks

### 0. Decide (before any code)

- [ ] Go version: StageX's pinned `stagex/core-go` (or `user-go`), the same digest pinned in
  `container/images`, signatures checked like the rest.
- [ ] The QR decoder (task 2): vendored, reviewed, pinned in `go.sum`.
- [ ] Whether the gate draws the donation QR codes itself (task 9) before or after the port:
  it removes `pixels_py` and most image decoding of the backend's images.

### 1. The module and its build

- [ ] `contrib/ccs-check/` in ccs-bash: `go.mod`, `main.go` (subcommands), packages `addr`,
  `scan`, `qr`, `pages`, `jsoncheck`; `vendor/` committed, so a build fetches nothing.
- [ ] Built in `container/gate.Dockerfile` from StageX's Go: `CGO_ENABLED=0`, `-trimpath`,
  `-buildvcs=false`, `-ldflags=-buildid=`, a fixed `SOURCE_DATE_EPOCH`; the binary copied into the
  image at `/usr/local/bin/ccs-check`, root-owned, 755.
- [ ] The release's gate image ID stays reproducible: CI's `gate-image` job builds it twice and
  compares, as today; `contrib/release/build` and attesters get the same bytes.

### 2. The QR decoder

- [ ] Candidates: a Go port of ZXing (e.g. `makiuchi-d/gozxing`), or a smaller QR-only decoder.
  Criteria: pure Go, no cgo, maintained, small enough to read, decodes qrencode's output and
  rejects what `gate-image.sh` rejects.
- [ ] Review it (what it parses, its limits), vendor it, pin it.
- [ ] Image limits as today, before decoding: `image.DecodeConfig` first, refuse over 40 million
  pixels; files over 8 MB not read.

### 3. Port, one subcommand at a time (each with Go tests)

- [ ] `addr`: base58 (Monero's 8-byte blocks), Keccak checksum, network prefixes; Go tests from
  `check_py`'s cases.
- [ ] `json`: as `json_py`.
- [ ] `scan`: as `scan_py`: runs of 90, groups with separators, NFKC look-alikes, bidi controls,
  NUL bytes; every case `run.sh`/`gate.sh` has for it.
- [ ] `qr` and `pixels`: as `qrscan_py` and `pixels_py` (unless task 9 comes first).
- [ ] `pages`: the design's pages and parts, region by region between the `ccs:` markers (RE2 has
  no backreference: the donation box's address is read once and compared in Go, not by `(?P=)`).
  The same slots and patterns as `pages_py` (TEXT, NAME, XMR, DATE, LINK, the onion, Funded at
  100, `needed_note`, `pending_note`).
- [ ] `rrsync`: decide between a Go subcommand and the shell rrsync; keep its tests
  (`tests/rrsync.sh`).

### 4. Shadow mode (both run, Python decides)

- [ ] ccs-receive runs both on every push; Python's result is used; any difference is logged
  and alerted once (`alert check-differs`), with the file and both answers.
- [ ] `gate.sh` and `gate-image.sh` run with both, and fail on any difference.
- [ ] Deployed to node2 for at least two weeks of real pushes (and the daily full recheck) with
  no difference, or each one explained and fixed.

### 5. Switch (Go decides, Python still installed)

- [ ] ccs-receive uses `ccs-check`'s results; Python runs only if `CCS_GATE_PYTHON=1` (a way
  back without a release).
- [ ] A release, attested; the handover's deploy notes say so.

### 6. Remove Python

- [ ] ccs-receive: the Python blocks and `CCS_GATE_PYTHON` gone.
- [ ] `container/images` and `gate.Dockerfile`: python, libffi, zbar, libpng, libjpeg, giflib
  out (qrencode stays if task 9 uses it).
- [ ] The host setup (two-machines.md, setup.md): `apt install` without python3 and the image
  libraries; ccs-receive's "Needs" line.
- [ ] `docs/python.md` replaced by `docs/ccs-check.md` (what it checks, how it's built, patched).
- [ ] Tests' own Python helpers (`tests/gate.sh` image making, `watch.sh`) may stay: CI only.

### 7. Security review

- [ ] A review (review 9) of `ccs-check` before task 5: input limits, every refusal reason,
  path handling (nothing outside staging and live), the QR decoder's behaviour on hostile
  images, and that shadow mode found no difference.
- [ ] Fuzz tests (`go test -fuzz`) for `scan`, `qr` and `pages` on hostile input, run in CI for a
  fixed time.

### 8. Keeping it patched

- [ ] Go security releases: a StageX pin refresh (`container/update-images.sh`,
  `update-sigs.sh`), rebuild, release, as for any pinned image.
- [ ] The vendored modules: `govulncheck` in CI; an update is a reviewed commit to `vendor/`.

### 9. (Optional, independent) The gate draws the donation QR codes

- [ ] The design references `/qr/<address>.png`; the gate writes it with qrencode from an
  address it already checked against the signed list; ccs-front-bash no longer embeds a QR
  code.
- [ ] ccs-watch fetches each donation page's QR image and checks it encodes the page's address
  (the backend checking the web server, as it checks the pages).
- [ ] Removes `pixels_py` and the decoding of backend images; QR reading stays for the proposals'
  own images.

## Done when

The gate's image has no Python, libffi or C image library; `run.sh`, `gate.sh`, `gate-image.sh`,
`web.sh` and `regtest.sh` pass; the fuzz tests run in CI; a release with `ccs-check` is attested
and deployed; review 9 has no open High or Medium.

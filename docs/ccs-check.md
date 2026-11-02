# ccs-check: the gate's checks

ccs-bash is bash, awk and jq, except in one place: the web server's gate,
[`contrib/ccs-receive`](../contrib/ccs-receive), which checks every push from the backend before
it goes live. Its checks are one static Go binary, [`ccs-check`](../contrib/ccs-check), built
reproducibly by StageX's Go; nothing on the servers runs Python (the gate's checks were Python
until they were ported). Some test scripts use Python; they run in CI and on a developer's
machine.

## What it does

| Subcommand | What it checks |
|---|---|
| `pages` | every page is the design's, its regions filled only with the design's parts, a proposal's text as the proposals repository has it, a donation box one address of the signed list |
| `scan`, `json`, `nul` | every address in the pages, JSON and feed, also spaced out, split (between elements too) or drawn with look-alikes (Monero's base58 and Keccak checksum), is the wallet's or allowed; `projects.json` reads as JSON; no NUL byte |
| `pixels` | a QR code is, pixel for pixel, qrencode's of the address it should be: the backend's QR codes are compared this way, never decoded |
| `qr` | the QR codes in a proposal's images (from the proposals repository), as a browser shows them: Go's own image decoders (the format by the bytes, a GIF's frames drawn over each other; an animated PNG or a GIF of over 100 frames held back), gozxing's QR reader, inverted and faint codes too |
| `rrsync` | receives the push, as `rrsync -wo -no-del -munge` did: only the backend's push (`rsync -a --delay-updates SITE/ host:`), nothing else |

Each subcommand takes the command line the Python block it replaced took and printed the same
lines: it was checked against that Python on generated and mutated files, and on the live
testnet site (326 pages, every answer the same), before the Python was removed. Since then,
review 9: `qr` reads what the Python missed (animation frames, a format other than the name's,
inverted and faint codes beside others), `scan` an address split between elements, and `pixels`
refuses a PNG another decoder would read otherwise. Its own tests:
`contrib/ccs-check/build.sh test` (Go tests) and `fuzz` (CI).
Anything that can be plain text matching stays awk (the feed check, `feed_awk`).

## Built from

- **Go:** StageX's (`container/images`, `go`), by digest, its signatures checked
  ([image.md](image.md)); `CGO_ENABLED=0`, `-trimpath`, no network: `contrib/ccs-check/build.sh`
  and the gate's image make the same bytes (attesters sign the gate image; a host setup copies it
  out of that image, [two-machines](two-machines.md#without-docker)).
- **Two modules**, from pinned archives (`container/sources.lock`, by sha256), unpacked by
  `contrib/ccs-check/deps.sh`, which first checks each archive's files are the ones Go's checksum
  database has for that version (their `h1:`, as go.sum has it):
  gozxing, only its QR reader's files (`deps/gozxing.files`) with `deps/gozxing.patch` (a code's
  bytes read as ISO-8859-1, so no byte of a multi-byte character hides an address's; no
  golang.org/x/text); and golang.org/x/xerrors.
- **Our own code** for the rest (`addr`: base58 and Keccak; `pages/match.go`: the page patterns'
  matcher; `pixels`: the PNG reader for qrencode's PNGs only).

## Who can reach it

ccs-check never sees a visitor. Its only input is a push from the backend:

- **one SSH key**, the backend's, `from=` its address, `restrict`, and a fixed command
  (`ForceCommand=/usr/local/bin/ccs-receive`): it can't open a shell or run anything else;
- **only the files in that push** (and the gate's own read-only config: the signed list, the
  design, the proposals it fetched itself).

## What limits it

- **Memory-safe**: Go, no cgo, no `unsafe` (nor in the two modules): a bug is a wrong answer or
  a crash, not code run. A crash holds the files back; a wrong answer may pass one, which is what
  the reviews and fuzz tests look for. Of what a push brings, only rsync (C, as before) reads it
  unchecked, receiving it; no C library decodes it (the image's libpng is qrencode's, writing the
  reference QR codes).
- **Limits:** a time limit on every run (`timeout`, 20 seconds to 5 minutes; `qr` has its own,
  15 s); a file over 8 MB isn't read, a page over 2 MB isn't matched; `qr` decodes nothing over
  40 million pixels; `qr` and `pages` take 1 GB at most; the container has 2 GB and 256 processes.
- **No root**: sshd hands the push to the `ccs-data` account; ccs-check runs as it. The
  container is read-only but for its own folders, with no capabilities beyond sshd's and
  `no-new-privileges`.
- **Failing closed**: a crash, a timeout, an image it couldn't check (`qr` exits 2), no design
  release to check a page against: held back (its last good copy stays live) or the push
  refused.
- **No XML or HTML parser**: pages and the feed are matched as text against the exact form the
  design and ccs-front-bash write.

What it does **not** stop: ccs-check runs as `ccs-data`, which can write the live site's files
(that is its job). A compromised backend that found a way to make the checks pass a bad page
could change the site, as a compromised gate could; hence the reviews, the fuzz tests (CI) and
keeping it patched.

## Keeping it patched

- **Go:** CI's `vulncheck` workflow (weekly, and on each change to ccs-check or the pins) runs
  govulncheck on ccs-check as built: it fails on a known vulnerability in code ccs-check calls,
  and lists the rest. A failure is a StageX pin refresh (`container/update-images.sh`,
  `update-sigs.sh`; StageX publishes a Go release some days after Go does) and a release.
- **The modules:** a new archive in `container/sources.lock` (and `deps/gozxing.patch` checked
  against it), a reviewed commit, a release.
- **When:** only when vulncheck fails (ccs-check has no network code, where most of Go's
  vulnerabilities are) or a bug is found; one it only lists waits for the next release made
  anyway.

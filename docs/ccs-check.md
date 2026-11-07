# ccs-check: the gate's checks

ccs-bash is bash, awk and jq, except in one place: the web server's gate,
[`contrib/ccs-receive`](../contrib/ccs-receive), which checks every push from the backend before
it goes live, and of the site the web server builds from it. Its checks are one static Go binary, [`ccs-check`](../contrib/ccs-check), built
reproducibly by StageX's Go; nothing on the servers runs Python (the gate's checks were Python
until they were ported). Some test scripts use Python; they run in CI and on a developer's
machine. The backend's image has it too, for ccs-watch, which reads the live pages' addresses
with its `scan` (as the gate reads them).

## What it does

| Subcommand | What it checks |
|---|---|
| `data` | the push, `site-data.json` (`sitedata/sitedata.go`): every key once, byte for byte as ccs-bash writes it, and no other, each value of its kind; each index the signed list's, never 0, one proposal's only, and for a proposal the live site has given an address that one, never none (the gate's pins, `/var/lib/ccs-gate/pins`, and its `projects.json`); amounts and dates as ccs-bash writes them; an idea's name and author plain text with no address in it, its link a merge request of the proposals repository. Writes what it read again (`Clean`): what the site is built from |
| `gate` | which files of the site built here go live (`gate/gate.go`): the scans below over every page, JSON file and the feed (no address in the feed), and every QR code `qr/<address>.png` the signed list's own file (its sum in `.qr.sha256`; never decoded); a file it can't read fails |
| `scan`, `json`, `nul` | every address in the pages, JSON and feed, also spaced out, split (between elements too) or drawn with look-alikes (`addr/lookalike.go`: Cyrillic, Greek, full-width, mathematical; Monero's base58 and Keccak checksum), is the wallet's or allowed; no bidi control (U+202A-202E, U+2066-2069, as itself or an entity); `projects.json` reads as JSON; no NUL byte |
| `receive` | receives the push, `site-data.json` as it is on stdin, or nothing, the heartbeat (`contrib/ccs-push`): over 4 MB, or not a JSON object, is refused; written beside staging's `site-data.json` and renamed over it (a link there replaced, never followed) |
| `copy` | the site built into the live site (rsync -a's quick check, each file renamed into place, 644/755; `--delete`: what the build no longer has goes) |

Each subcommand takes the command line the Python block it replaced took and printed the same
lines: it was checked against that Python on generated and mutated files, and on the live
testnet site (326 pages, every answer the same), before the Python was removed. Since then,
review 9: `scan` finds an address split between elements. Gone since: `pixels`, which compared
the backend's QR codes with qrencode's (they are the signed list's files now, taken by their
sums), and `qr`, which read QR codes in the proposals' images with gozxing (a proposal's image is
taken as the proposals repository has it, byte for byte: that repository's review vouches for
what it shows; [the web server](web-server.md#what-it-guarantees-and-what-not)). Its own tests:
`contrib/ccs-check/build.sh test` (Go tests) and `fuzz` (CI). Gone since the web server builds
the site itself: `pages`, which matched every pushed page against the design (`pages.go`, its
matcher `match.go`, `front.go`, `projects.go`: about 1,800 lines), and the feed's check
(`lib/feed.awk`): the gate builds them now, from data it checks.

## Built from

- **Go:** StageX's (`container/images`, `go`), by digest, its signatures checked
  ([image.md](image.md)); `CGO_ENABLED=0`, `-trimpath`, no network: `contrib/ccs-check/build.sh`
  and the two images make the same bytes (attesters sign them).
- **No module**: Go's standard library and our own code only (`addr`: base58 and Keccak;
  `push`: the push's one file, and the copy into the live site).
  `go.mod` requires nothing, so there is nothing to fetch, pin or patch.

## Who can reach it

ccs-check never sees a visitor. Its only input is a push from the backend:

- **one SSH key**, the backend's, `from=` its address, `restrict`, and a fixed command
  (`ForceCommand=/usr/local/bin/ccs-receive`): it can't open a shell or run anything else;
- **only the files in that push** (and the gate's own read-only config: the signed list, the
  design, the proposals it fetched itself).

## What limits it

- **Memory-safe**: Go, no cgo, no `unsafe`: a bug is a wrong answer or
  a crash, not code run. A crash holds the files back; a wrong answer may pass one, which is what
  the reviews and fuzz tests look for. What a push brings is read by Go alone: taken by
  `receive`, read by `data`; no C program parses it (no rsync, no image library). The
  only C that touches the backend is sshd, before any of this. No image is decoded at all.
- **Limits:** a time limit on every run (`timeout`, 20 seconds to 5 minutes); a push over 4 MB
  isn't taken; the container has 2 GB
  and 256 processes.
- **No root**: sshd hands the push to the `ccs-data` account; ccs-check runs as it. The
  container is read-only but for its own folders, with no capabilities beyond sshd's and
  `no-new-privileges`.
- **Failing closed**: a crash, a timeout, a file it can't read: that file fails (it goes off the
  site), or nothing new goes live.
- **No XML or HTML parser**: the pages are scanned as text; `site-data.json` is read by
  `encoding/json`, strictly.

What it does **not** stop: ccs-check runs as `ccs-data`, which can write the live site's files
(that is its job). A compromised backend that found a way to make the checks pass a bad page
could change the site, as a compromised gate could; hence the reviews, the fuzz tests (CI) and
keeping it patched.

## Keeping it patched

- **Go:** CI's `vulncheck` workflow (weekly, and on each change to ccs-check or the pins) runs
  govulncheck on ccs-check as built: it fails on a known vulnerability in code ccs-check calls,
  and lists the rest. A failure is a StageX pin refresh (`container/update-images.sh`,
  `update-sigs.sh`; StageX publishes a Go release some days after Go does) and a release.
- **When:** only when vulncheck fails (ccs-check has no network code, where most of Go's
  vulnerabilities are) or a bug is found; one it only lists waits for the next release made
  anyway.

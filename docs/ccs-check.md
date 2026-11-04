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
| `pages` | every page is the design's, its regions filled only with the design's parts, a proposal's text as the proposals repository has it, a donation box one address of the signed list and its proposal's (the live site's `projects.json`'s), its QR code `qr/<that address>.png` (the file itself: the list's, by its sum, `ccs-receive`; never decoded); `projects.json` each entry its proposal's front matter, its address its own (`pages/projects.go`) |
| `scan`, `json`, `nul` | every address in the pages, JSON and feed, also spaced out, split (between elements too) or drawn with look-alikes (Monero's base58 and Keccak checksum), is the wallet's or allowed; `projects.json` reads as JSON; no NUL byte |
| `receive` | receives the push, a tar of the files that changed (`contrib/ccs-push`): plain files only (a folder only as a file needs it: a folder entry makes nothing), at clean paths under staging, each written beside and renamed into place, within its limits; anything else refuses the whole push (in place of rsync, which the gate no longer has) |
| `copy` | the live site into staging before a push, staging into the live site after (rsync -a's quick check, each file renamed into place, 644/755) |

Each subcommand takes the command line the Python block it replaced took and printed the same
lines: it was checked against that Python on generated and mutated files, and on the live
testnet site (326 pages, every answer the same), before the Python was removed. Since then,
review 9: `scan` finds an address split between elements. Gone since: `pixels`, which compared
the backend's QR codes with qrencode's (they are the signed list's files now, taken by their
sums), and `qr`, which read QR codes in the proposals' images with gozxing (a proposal's image is
taken as the proposals repository has it, byte for byte: that repository's review vouches for
what it shows; [the web server](web-server.md#what-it-guarantees-and-what-not)). Its own tests:
`contrib/ccs-check/build.sh test` (Go tests) and `fuzz` (CI).
Anything that can be plain text matching stays awk (the feed check, `feed_awk`).

## Built from

- **Go:** StageX's (`container/images`, `go`), by digest, its signatures checked
  ([image.md](image.md)); `CGO_ENABLED=0`, `-trimpath`, no network: `contrib/ccs-check/build.sh`
  and the gate's image make the same bytes (attesters sign the gate image).
- **No module**: Go's standard library and our own code only (`addr`: base58 and Keccak;
  `pages/match.go`: the page patterns' matcher; `push`: the push's tar, read with `archive/tar`).
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
  the reviews and fuzz tests look for. What a push brings is read by Go alone: the tar by
  `receive`, the files by the checks; no C program parses it (no rsync, no image library). The
  only C that touches the backend is sshd, before any of this. No image is decoded at all.
- **Limits:** a time limit on every run (`timeout`, 20 seconds to 5 minutes); a push over 512 MB
  (64 MB a file) isn't taken, a page over 2 MB isn't matched; `pages` takes 1 GB at most; the
  container has 2 GB and 256 processes.
- **No root**: sshd hands the push to the `ccs-data` account; ccs-check runs as it. The
  container is read-only but for its own folders, with no capabilities beyond sshd's and
  `no-new-privileges`.
- **Failing closed**: a crash, a timeout, no design release to check a page against: held back
  (its last good copy stays live) or the push refused.
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
- **When:** only when vulncheck fails (ccs-check has no network code, where most of Go's
  vulnerabilities are) or a bug is found; one it only lists waits for the next release made
  anyway.

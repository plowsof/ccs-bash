# The web server: the one machine to review

The web server is the only machine a visitor reaches, and it builds the site itself. The backend
(ccs-bash and the wallet) sends only what it alone knows, `site-data.json` (each proposal's
subaddress index, its dates and funds, the ideas); the gate checks it, builds every page from it
and from what it holds itself (the proposals repository it fetches, the design and the signed
list), checks what it built, and keeps a file that fails off the site. So whoever is asked to
trust the site (the Core Team) reviews this machine, and needn't trust the backend or whoever runs
it: a backend taken over can't put an address on the site that isn't the wallet's.

This page is the list: what runs there, its exact parts and versions, the code to read, the files
installed by hand, and how to check the running machine is the one reviewed. How the gate checks
push: [two machines, "The gate"](two-machines.md#the-gate-the-web-server-builds-the-site-itself);
setting it up: [the web server in Docker](docker.md#the-web-server-in-docker).

## What it guarantees, and what not

Every address on the site, as text or link, however written or split (entities, groups, markup),
with letters drawn as an address's (the Cyrillic, Greek, full-width and mathematical ones:
`addr/lookalike.go`), is one of the signed list's (the wallet's 15,000 subaddresses, signed by a
Core Team member) or in `allowed` (the General Fund), and no page has a bidi control that could
show one in another order than it is written; every page is the design's, filled by the gate
itself; a proposal's text, milestones, payouts, images and merge request are what the proposals
repository has (the gate fetches it itself: [why](reviewing.md)); a donation box's address is the
list's line of the index the backend gave when the proposal first went live (the gate's pins: no
push changes it, nor hides the proposal to), and its QR code the list's own file of that address.
The site is built from `site-data.json` as the gate's check read it, written again, never from the
bytes pushed. A file that fails is taken off the site, and the gate tells IRC, as it does of any
page leaving; more than three leaving within a day wait for a person.

**The proposals repository is trusted as reviewed.** What a merged proposal says, links to and
shows is that repository's review's to vouch for: the gate makes a page from its file, and scans
what it made for addresses, but doesn't judge what the file says. Its images are taken byte for byte as the repository has them, and
never read: an image can show an address, or a QR code of one, as any picture can. So reviewers
check a proposal's images when merging. A taken-over forge could rewrite proposals, link out of
the site from one, or show an address in an image; it could not change a donation box (its
address and QR code are the wallet's and the list's) or put an address on a page as text, and the
money stays in the CCS wallet.

Not: what only the backend knows, a total or percentage that is wrong but a number, the address a
proposal new to the site is first given (one no other proposal has; from then on it is that
proposal's), the dates only the backend keeps; a proposal's name, author, goal, stage and tags are
its front matter's, read from the repository by the gate itself
([in full](two-machines.md#the-gate-the-web-server-builds-the-site-itself),
"What it can't see"). Nor anything once this machine itself is taken over: then ccs-watch (the
backend fetching the site as a visitor) and the Verify page (visitors checking an address in a
view-only copy of the wallet) are what's left.

## What runs on it

| Part | From | Reviewed as |
|---|---|---|
| **the gate** (sshd on 2223, the push key's forced command `ccs-receive`: the push is `site-data.json` as it is, taken in Go; the site built from it) and **the heartbeat** | the gate's image, `contrib/docker/web/compose.yml` | this page: its code, its image's parts |
| **the site**: Caddy (`www`: serves `/var/lib/ccs-data`, the live site, read-only, over HTTPS, its certificates its own; the security headers) and Tor (`tor`: the onion) | the gate's image; their config, [`Caddyfile`](../contrib/docker/web/Caddyfile) and [`torrc`](../contrib/docker/web/torrc), in it | this page: their config, their image's parts |
| Docker, the OS | the host's Debian or Ubuntu packages, `unattended-upgrades` | not reviewed here: the distribution's |
| your own ssh | [admin access](admin-access.md) | yours |

The backup receiver (`ccs-backup-receive`, the same image) runs on **the backup machine**, not
here ([the design](design.md)).

### The gate's image

One image, built from the attested ccs-bash commit (`container/build.sh ccs-gate
gate.Dockerfile`), the same image ID from the same commit anywhere, attested in
[ccs-sigs](https://github.com/plowsof/ccs-sigs) as `ccs-gate-vX.Y.Z`. Every package is
[StageX](https://stagex.tools)'s: built from source from a small bootstrap, reproduced and signed
by two or more of its maintainers, pinned here by digest (`container/images`) and its signatures
checked on every build ([the pinned image](image.md#signatures)). Nothing is downloaded while it
builds.

| Package | Version | Why it is there |
|---|---|---|
| openssh (`sshd`, `ssh-keygen` only) | 10.5p1 | the push's channel: runs only the forced command, `site-data.json` on its stdin (no C program reads it: `ccs-check receive` takes it) |
| git | 2.55.0 | fetches the proposals repository itself (https) |
| curl, openssl, ca-certificates | 8.22.0, 3.6.4 | the gate's IRC alerts; git's https |
| jq | 1.8.2 | the site built here (`site.jq` and ccs-front-bash), reading only JSON `ccs-check data` passed and the gate's own |
| bash 5.3; **busybox** 1.38.0, built here from its source (`sources.lock`: StageX's sum for it) with only the 40 applets (and 3 of their options) in [`container/gate-busybox-applets`](../container/gate-busybox-applets) (`awk`, `find`, `grep`, `sed`, `sha256sum`, `tar` for `git archive`, `flock`…), as the ccs-bash image's | | `ccs-receive`, `ccs-backup-receive`, `init`, the healthchecks, the site's build, as written and tested |
| musl 1.2.6, ncurses 6.6 (bash's `libncursesw` only), zlib 1.3.2, libzstd 1.5.7 | | their libraries (each linked by one of the above: checked) |
| **ccs-check** | this repository's `contrib/ccs-check` | the checks (below), built by StageX's Go 1.27.1, no cgo, no module |
| caddy | 2.11.4 | the site over HTTPS (`www`), its certificates from Let's Encrypt; HTTP/1.1 only, `Range` ignored, headers capped: [two machines](two-machines.md) |
| **tor** | 0.4.9.15, built here from its source (`sources.lock`: the tarball's sha256, from its `.sha256sum` signed by two of Tor's release signers) | the onion (`tor`); a client and onion service only, no relay or directory authority code; linked to StageX's libevent 2.1.13, OpenSSL and zlib |

The versions are those of the pinned digests (StageX release sx2026.10.0); `container/images`
is the source of truth, and `container/update-images.sh` moves every pin to StageX's latest
release, checking its signatures (review the diff, as any other). Not in it: Python, qrencode,
libpng, zbar, libjpeg, giflib, rsync, xxhash, acl, attr, an ssh client, sftp, git's servers
(`tests/gate-image.sh` fails if any is). Nothing on it decodes an image.

`ccs-check` has **no module**: Go's standard library and this repository's code only, nothing
third-party to pin or review. [ccs-check.md](ccs-check.md): what each check does, and keeping it
patched (`govulncheck` in CI, for Go itself).

## The code to read

About 3,900 lines, this repository's own and the ccs-front-bash release it vendors:

| File | Lines | What it is |
|---|---|---|
| [`contrib/ccs-receive`](../contrib/ccs-receive) | 350 | the gate: takes only `receive`, receives `site-data.json` alone, fetches the proposals repository, checks the data (`ccs-check data`, which writes what the site is built from), builds the site (`ccs-gate-build`), runs `ccs-check gate` on it, copies it live but what failed, alerts (each page leaving too); the pins and the day's removals; the heartbeat |
| [`contrib/ccs-check/`](../contrib/ccs-check) (Go, tests aside) | 1,730 | `data` (`sitedata/sitedata.go`: `site-data.json`, each key exactly as ccs-bash writes it, each value of its kind, each index the list's and its proposal's, the pins), `gate` (`gate/gate.go`: which built files go live), `receive` and `copy` (`push/push.go`: the push's one file, 4 MB at most; the copy into the live site), `scan` (`scan/scan.go`, `addr/addr.go`, `addr/lookalike.go`: every address, by Monero's checksum, in look-alike letters too; no bidi control) |
| `contrib/ccs-check/build.sh` | 71 | how it is built and tested (StageX's Go, no network) |
| [`container/gate.Dockerfile`](../container/gate.Dockerfile) | 132 | what goes in the image, Tor built from its source among it |
| [`contrib/docker/web/`](../contrib/docker/web) (`compose.yml`, `sshd_config`, `init`, `env.example`, `Caddyfile`, `torrc`) | 353 | how it runs: one user each, the forced command, read-only, sshd's three capabilities, limits; what Caddy serves and how, the onion |
| `container/build.sh`, `verify-images.sh`, `fetch.sh`, `verify.sh` | 206 | the build: the pins' signatures and sums checked |
| [`contrib/gate-build`](../contrib/gate-build), with ccs-bash's [`lib/site-data.sh`](../lib/site-data.sh), [`site.jq`](../lib/site.jq), [`proposals.sh`](../lib/proposals.sh), [`images.sh`](../lib/images.sh), [`common.sh`](../lib/common.sh), [`frontmatter.awk`](../lib/frontmatter.awk) | 580 | the site built here, with ccs-bash's own steps: the proposals' front matter and images from the repository fetched here, each one's merge request from its merge commits (`merge_requests`), each address the signed list's line of its index |
| [`vendor/ccs-front-bash/`](../vendor/ccs-front-bash) | 817 | the ccs-front-bash release that fills the design (`lib/markdown.awk`: a proposal's text, escaped first; `RELEASE`: its tag and commit; CI checks the copy is that commit's, `contrib/vendor-front-bash --check`) |

And what the site is built with, from the other repository: ccs-front-hugo's **design** (its
release zip: the pages, the parts they are filled with, the stylesheets and images; installed by
its sha256).

The tests show each way around it, by name: `tests/gate.sh` (every check, hostile pushes, with
this image as the web server and the design's real release), `tests/gate-image.sh`, `tests/web.sh` (its sshd,
attacked), `contrib/ccs-check/build.sh test` and `fuzz` (the scan and the data check, whatever they are
given). [Reviewing](reviewing.md) walks each function.

## What is installed by hand

The gate trusts only what root installs here; each from its own source, checked here, never pushed:

| File, in `/etc/ccs-gate/` | From | Checked by |
|---|---|---|
| `subaddresses.txt`, `.asc`, `.key.asc`, `.pin`, `.viewkey` | the signed list (this repository's `subaddresses/<wallet>/`) | `tools/verify-subaddresses.sh` with a `list-signers` of your own ([the signed list](signed-list.md)) |
| `subaddresses.txt.qr.sha256`, `subaddresses.txt.qr/` | the list's QR codes and their sums (`tools/make-qr.sh`) | the same: it remakes every QR code, and the `.pin`'s `qr` line pins the sums; each code against its sum, `sha256sum -c` |
| `design/<release>/` | the design's release zip | its sha256, the attested one |
| `allowed` | you: other addresses the site may show (the General Fund) | you |
| `proposals.conf` | you: the proposals repository and branch, the forge its merge requests are on | you |
| `alert.conf`, `onion` | you: the IRC bot, `SITE_URL`; the site's onion | you |
| `ssh/` | the gate's own sshd host key | made by `init` the first time |
| `/etc/ssh/authorized_keys/ccs-data` (outside `/etc/ccs-gate/`) | the backend's push key, its line with `from=`, `command=`, `restrict` | you ([two machines](two-machines.md)) |

A list or QR codes' sums that aren't the pinned ones, or no design release, refuses every push.

## Checking the running machine is the one reviewed

1. **The image:** its ID in `contrib/docker/web/.env` (`CCS_GATE_IMAGE`) is the one two or more
   signers attested for that release: `contrib/release/verify ccs-gate-vX.Y.Z` with your own
   `trusted-signers`; and the image you built from that commit has that ID
   ([deploying a set](deploying.md), steps 1 and 2).
2. **What is running:** `docker compose ps` (the gate and the heartbeat, healthy) and
   `docker inspect --format '{{.Image}}' web-gate-1`: the attested ID.
3. **Its files:** the table above, each against its source.
4. **What it serves:** ccs-watch, on the backend, fetches the live pages as a visitor and checks
   their addresses against the signed list and each donation box against its proposal's; any
   visitor can check an address on the Verify page.

## What doesn't need reviewing

The backend: ccs-bash's run (the totals, `site-data.json`), monero-wallet-rpc, the backend's
compose and its host. Whatever they get wrong or are made to do, all they can send is
`site-data.json`, and the gate holds back one that isn't as ccs-bash writes it. They are reviewed
for the numbers, not the addresses: see [reviewing](reviewing.md).

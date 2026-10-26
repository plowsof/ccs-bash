# Reviewing: what each file does

Only the code that runs on the live machines, in the order a run uses it, with what each part
checks. Left out: the tests, the container build (`container/`), the release tools
(`contrib/release/`) and the design ([ccs-front-hugo](https://github.com/plowsof/ccs-front-hugo),
built offline). Every script is `set -euo pipefail`, `LC_ALL=C` and shellcheck-clean; the awk is
POSIX (mawk, gawk, busybox).

The rule everything serves: every donation address shown, as text, link or QR code, is one of the
wallet's. [The design](design.md) says why it is built this way.

## Backend (no inbound connections)

Root's `ccs-bash-update` ([handover](handover.md#9-the-update)) runs one update, starting each step
as its own user: `git pull` as `ccs-git`, ccs-bash as `ccs`, ccs-front-bash as `ccs-front`, the push
and the watcher as `ccs`.

- [`notify-loop.sh`](../notify-loop.sh), root (systemd): runs `ccs-bash-update` every 120 s, or sooner
  once wallet-rpc's `tx-notify` has touched a flag file (never read, only checked for), at most
  once per 30 s.

### ccs-bash: proposals, GitLab and the wallet to JSON

Pinned container, read-only, no capabilities, `--network host` only to reach wallet-rpc on
127.0.0.1.

- [`ccs-back.sh`](../ccs-back.sh): `main` is the run: config, `flock`, proposals, state, wallet
  checks, totals, new proposals' merged MRs, new subaddresses, funds, ideas (GitLab down: the last
  list), images, the JSON.
- [`lib/common.sh`](../lib/common.sh): `load_config` sources the config and **refuses to run if
  this user can write it** (it pins `WALLET_ADDRESS`); `atomic_write` (temp file, sync, rename; a
  failure keeps the old file); `safe_filename` (a plain `*.md`: no `/`, control characters, leading
  dot or backslash); `log` turns control characters into `?`.
- [`lib/frontmatter.awk`](../lib/frontmatter.awk): a strict subset of YAML (spec at its top): one
  tab-separated line per valid proposal. Anything Jekyll could read differently skips the file,
  with the reason.
- [`lib/proposals.sh`](../lib/proposals.sh): `read_proposals` takes plain files only (no symlink,
  directory or fifo), safe and valid UTF-8 names, through frontmatter.awk to JSON. `load_state` and
  `save_state`: `proposals.csv` to JSON and back (the CSV parsed by a jq regex). The state is never
  created: missing, the run stops.
- [`lib/wallet.sh`](../lib/wallet.sh): `rpc` is JSON-RPC by curl, the login on a pipe, not in `ps`.
  `check_wallet_addresses`: the main address is `WALLET_ADDRESS` and every subaddress in the state
  is the wallet's (a restored wallet gets them re-created). `assign_addresses`: a new subaddress per
  funding-required proposal, its index above every index in the state. `donation_totals`:
  the deposits 30 blocks deep kept in `STATE_DIR/deposits.csv` (a cache), then `get_transfers`
  (in and pool) from that height only (`filter_by_height`); everything once a day, compared: a
  wallet without a kept deposit, or below the file's height, stops the run (never lower totals).
  Deduplicated by txid and index; a time-locked one counted once its lock has passed (`locked`),
  ignored before; every field checked (digits, a 64-hex txid) before bash arithmetic (a subscript
  can run commands) and before it goes in the file; sums in 64-bit bash, not jq's doubles. `check_wallet_addresses` also labels each subaddress in the state with its
  proposal's file (`label_address`; a wallet from ccs-back or restored has none), as
  `assign_addresses` labels new ones. `check_known_subaddresses`: donations at a labelled index
  the state doesn't have stop the run (a lost state); at an unlabelled one, which anyone can send
  to from the signed list, they are logged and counted for no proposal. `qr_codes`: for the old
  Jekyll front only; ccs-front-bash makes its own.
- [`lib/gitlab.sh`](../lib/gitlab.sh): the public API of GitLab or Forgejo (Forgejo's pull requests
  mapped to GitLab's shape). `merged_mr_url`: the merged MR that added a file. `mr_proposal_file`:
  an MR is an idea only if it adds exactly one `.md` at the root, and besides it only files in
  `images/<its name>/`. `ideas`: open MRs whose file reads as a proposal, the `IDEAS_MAX` (100) most recently updated,
  what each adds at its commit, and whether its file reads, kept in `STATE_DIR/ideas.cache`
  (anyone can open MRs: each is fetched once, not every run); title and author
  HTML-escaped, bidi controls dropped, any run of 90 or more characters each base58 or not ASCII
  (invisible characters, look-alike letters) shortened, as the gate's `TEXT` rule (an MR title can't carry an address to the gate), links
  `https:` only; its file 1 MB at most.
- [`lib/images.sh`](../lib/images.sh): copies the images a proposal's Markdown shows from
  `images/<proposal>/` (plain files, PNG, JPEG or GIF by their first bytes, 2 MB at most) and writes
  `images.json`. No network.
- [`lib/site.jq`](../lib/site.jq): `proposals.json`, `completed-proposals.json`, `projects.json`;
  every text `@html`, every link `https:` only.

### ccs-front-bash: the JSON and the design to the site

[Its repository](https://github.com/plowsof/ccs-front-bash). Pinned container, no network,
read-only, its own user; reads the design, the JSON, the proposals and the signed list, writes
`site/`.

- `ccs-front-bash.sh`: `main` copies the design (not `parts/`), fills the lists, tag pages and
  proposal pages into `site.new`, then swaps it in (a failure keeps the last site).
  `check_addresses`: the list's sha256 is its `.pin`'s (else the run stops) and every donation
  address is in the list: a funding-required proposal whose address isn't is left off the site
  (its page, its cards, the counts) and the run exits 3; fills the Verify page. `qr_codes`: one QR code per checked address
  (qrencode); ccs-bash's are never used. `relative_links`: the data's absolute links made relative,
  so `/dark/` and `/light/` stay while browsing.
- `lib/fill.sh`: `fill_page` replaces each `<!-- ccs:x -->…<!-- /ccs:x -->` region in one pass,
  left to right (what goes in is never searched again); a missing, repeated or nested marker stops
  the run.
- `lib/common.jq`: a proposal's slot values; `escaped` refuses any value with `<>"'` (ccs-bash
  must have escaped it, so nothing is escaped twice or not at all); `page_file` refuses `/`, a
  leading dot and control characters; tag slugs and colours.
- `lib/regions.jq`, `lib/tags.jq`: the stage lists and the tag filters and pages, from the design's
  parts.
- `lib/pages.jq`: every proposal page in one jq run: the slots, the donation box (the address 95
  base58 characters, the QR code a PNG from `qr_codes`, else the run stops), milestones, and
  payouts where the design has them.
- `lib/markdown.awk`: a Markdown subset to HTML. Everything is escaped first, and only tags it
  writes itself appear (finished HTML is held as `\001n\002` placeholders, so later steps can't
  touch it; a proposal's own `\001` and `\002` are dropped). Links: `https:`, `#anchor`, or
  site-relative (`/` and a plain character: never `//`, `/\` or an entity, which a browser reads as
  another site). Images: only the proposal's copied ones, any other
  is a link.

### Push, watcher, backup

- The push: `rsync --delay-updates` as `ccs` to the web server's key, which runs only the gate.
- [`contrib/ccs-watch`](../contrib/ccs-watch), as `ccs`: fetches the donation pages (each under `/`,
  `/dark/` or `/light/` at random), every file they use, `WATCH_SAMPLE` other pages at random and
  `/projects`, and the fonts and icons the stylesheets use (`url()`), asking as Tor Browser does
  (its headers, `Sec-Fetch-*` by what is fetched, a page typed in, clicked on the site or from
  another at random), through
  a proxy picked at random, and compares each byte for byte with what was pushed. A difference must
  last three fetches over 40 s and two runs before it alerts; a page answering anything else than
  200 with a body, three checks in a row while the rest of the site answers, alerts too; `--run`
  alerts after three failed runs. Its config is read key by key, never sourced.
- [`contrib/migrate/compare-deposits`](../contrib/migrate/compare-deposits), once, moving from
  ccs-back: its `deposits` table against the first run's `deposits.csv`, by txid and subaddress;
  exits 1 if ccs-back has a deposit the wallet lacks, or another amount. Reads files only.
- [`contrib/ccs-backup-receive`](../contrib/ccs-backup-receive), on the backup machine, the
  backend's key's forced command: a `proposals.csv` (at most 1 MB, its rows' shape) is kept as a
  new dated file, never overwriting or deleting one; a `deposits.csv` (at most 64 MB, its first
  line `# final`) replaces the one copy only if it has every deposit that copy has. Nothing once
  its folder holds 256 MB.

## Web server

- [`contrib/ccs-receive`](../contrib/ccs-receive), the push key's forced command, as `ccs-data`:
  one push at a time (`flock`); staging starts as a copy of the live site; rrsync
  (`-wo -no-del -munge`) receives into it. The whole push is refused if the list isn't its `.pin`'s,
  or there is no `zbarimg`, `qrencode`, `python3`, `git`, `design.sha256`, design release,
  `markdown.awk` or `proposals.conf`, or a file name has a control character. `fetch`: the
  proposals repository's last two commits, each push (the last fetch if it can't be).
  `pages` (`pages_py`, Python's standard library only): every page must be one of the design's
  (`design/<release>/`, its zip unpacked), byte for byte outside its regions; each region a
  sequence of the design's parts and each `{{slot}}` a value of its kind, one regex per page
  built from the parts (`Design.fill`, `region`, `slots`); a proposal's text, milestones and
  payouts what `markdown.awk` makes of its file at one of those commits (`bodies`, kept by
  commit); a donation box one address of the signed list, its QR code that address's. A page it
  doesn't pass (`=ok`), whatever the reason, out of time included, is held back. `kinds`: no
  symlink, no folder in a file's place or file in a folder's. `scan` (`scan_py`, one pass) reads
  every page and JSON as written (entities decoded, a non-ASCII or control character both
  dropped and a space) for addresses, the JSON as JSON too (`json_py`), and every `data:` image (`qrdata`:
  zbarimg reads one listed address, and its pixels, read by `pixels_py`, are those of
  `qrencode -s 10` of it). A page or JSON must start with `<`, `[` or `{`. `changes`: any other
  file the push changes must be the design's (`design.sha256`), a proposal image the proposals
  repository has at that path (`repo_images`: `git hash-object` compared with `ls-tree`; its QR
  codes checked too), `projects.json`, or the list's files as installed in `/etc/ccs-gate`. A
  failing file is deleted from staging, so it keeps its last good copy; the rest goes live, the
  push fails, IRC is told. `--heartbeat` (a timer): alerts when no push has come for 15 minutes.
- nginx: static files, the security headers, the theme map ([two machines](two-machines.md)).

## Where an address is checked against the signed list

The rule everything serves, step by step, from a new proposal's subaddress to the visitor's
wallet. The list is the wallet's first 15,000 subaddresses, signed by a Core Team member's own
key; its `.pin` (sha256 and key) is what each machine trusts, installed by hand once
`tools/verify-subaddresses.sh` (ccs-front-bash) has checked who signed it ([handover](handover.md#4-the-signed-subaddress-list), step 4).

| Step | Where | What is checked | If not |
|---|---|---|---|
| 1. The wallet is the CCS wallet | `lib/common.sh` `load_config`; `lib/wallet.sh` `check_wallet_addresses` | `WALLET_ADDRESS` (root's config, which ccs-bash can't write) is the wallet's main address; every subaddress in the state is the wallet's at its index | the run stops |
| 2. A new proposal gets a subaddress | `lib/wallet.sh` `assign_addresses` | made by the wallet itself (`create_address`, labelled with the proposal), 95 characters, its index above every index in the state (never one already given) | the run stops. Not checked against the list here: ccs-bash doesn't read it; step 3 does, before anything is shown |
| 3. Every donation address is on the list | ccs-front-bash `ccs-front-bash.sh` `check_addresses` | the list is the one its `.pin` names (sha256); every funding-required proposal's address is a line of it | a wrong list: the run stops, no site is made. An address not on it: that proposal is left off the site, the run exits 3 (an address past index 15,000 too: make a longer list) |
| 4. Its QR code is made from it | ccs-front-bash `ccs-front-bash.sh` `qr_codes` | made here, from the checked address (`qrencode -s 10 "monero:<address>"`); ccs-bash's own QR codes are never used | the run stops |
| 5. The page holds them | ccs-front-bash `lib/pages.jq`, the donation box | the donation box gets that address and that QR code, else the run stops | the run stops |
| 6. The web server's list is the pinned one | `contrib/ccs-receive`, before the push is received | the gate's own copy (installed by hand) is the one its `.pin` names | every push refused, IRC told |
| 7. Every address on every page is on the list | `contrib/ccs-receive` `scan` (`scan_py`, `json_py`) | every 95- or 106-character address in a page or JSON, as written (entities read, a non-ASCII character as nothing and as a space), is a line of the list or in `allowed` | that file held back, its last good copy stays, IRC told |
| 8. Every QR code is of a listed address | `contrib/ccs-receive` `qrdata` (`pixels_py`) | each `data:` image is, pixel for pixel, `qrencode -s 10` of the `monero:` address zbarimg reads in it, and that address goes through step 7 | held back |
| 9. Addresses only where the design puts them | `contrib/ccs-receive` `pages` (`pages_py`, the `address` and `qr` slots) | a page is the design's, filled: an address can only be in the donation box's slots, each one address | held back |
| 10. What is live is what was pushed | `contrib/ccs-watch`, the page comparison (`differs`) | the live donation pages (and others at random) byte for byte; a live address not on the list is named in the alert | IRC told |
| 11. The visitor | the Verify page (`parts/verify.html`, filled by `check_addresses`) | the list, its signature and key, the signer's fingerprint; the commands to ask a copy of the wallet whether an address is its own (`get_address_index`) | the visitor doesn't pay |

Function names, not line numbers, so this stays right as the code moves. Steps 3–5 stop a wrong
address on the backend (whatever changes ccs-bash's JSON); 6–9 on the web
server (whatever the backend pushes); 10–11 catch a web server that serves something else.

## The dense parts

Where to slow down: `markdown.awk`'s `hold`/`unhold`; `ccs-receive`'s `pages_py` (the slot
rules: `TEXT`'s lookahead is what keeps an address out of a name, matched by `noaddress` in
`gitlab.sh`) and `scan_py`'s `entity` (entity decoding by hand); `load_state`'s CSV regex
(`proposals.sh`); `forgejo_prs`' time-zone conversion (`gitlab.sh`).

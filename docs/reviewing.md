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
  `get_transfers` (in and pool), time-locked ones left out, deduplicated by txid and index; every number checked
  to be digits before bash arithmetic (a subscript can run commands); sums in 64-bit bash, not
  jq's doubles. `check_known_subaddresses`: donations at an index the state doesn't have stop the
  run. `qr_codes`: for the old Jekyll front only; ccs-front-bash makes its own.
- [`lib/gitlab.sh`](../lib/gitlab.sh): the public API of GitLab or Forgejo (Forgejo's pull requests
  mapped to GitLab's shape). `merged_mr_url`: the merged MR that added a file. `mr_proposal_file`:
  an MR is an idea only if it adds exactly one `.md` at the root, and besides it only files in
  `images/<its name>/`. `ideas`: open MRs whose file reads as a proposal; title and author
  HTML-escaped, any run of 90 or more base58 characters shortened, invisible characters in it or
  not (an MR title can't carry an address to the gate), links `https:` only; its file 1 MB at most.
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
  `check_addresses`: the list's sha256 is its `.pin`'s and every donation address is in the list,
  else the run stops; fills the Verify page. `qr_codes`: one QR code per checked address
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
  `/dark/` or `/light/` at random) and every file they use, asking as Tor Browser does, through a
  proxy picked at random, and compares each byte for byte with what was pushed. A difference must
  last three fetches over 40 s and two runs before it alerts; `--run` alerts after three failed
  runs. Its config is read key by key, never sourced.
- [`contrib/ccs-backup-receive`](../contrib/ccs-backup-receive), on the backup machine, the
  backend's key's forced command: reads at most 1 MB (nothing once its folder holds 256 MB),
  which must look like `proposals.csv`, and keeps it as a new dated file; never overwrites or
  deletes one.

## Web server

- [`contrib/ccs-receive`](../contrib/ccs-receive), the push key's forced command, as `ccs-data`:
  one push at a time (`flock`); staging starts as a copy of the live site; rrsync
  (`-wo -no-del -munge`) receives into it. The whole push is refused if the list isn't its `.pin`'s,
  or there is no `zbarimg`, `git` or `design.sha256`, or a file name has a control character. `scan`
  (awk) reads every page and JSON four ways: as written (entities and %-escapes decoded), as shown
  (comments and tags removed as HTML reads them, `strip`), every `monero:` link and address box
  (one address, nothing else), and every `data:` image (a PNG that `zbarimg` reads as a QR code of
  a listed address, inverted codes too). Every non-ASCII or control character is dropped first, so
  none can split an address; `hidden`, `dir`, `style` and `popover` attributes and `<svg>`,
  `<template>`, `<bdo>`... (`hides`), which the design never uses, are refused, and so are block,
  square and braille characters (`drawing`), which can draw a QR code as text. `changes`: any other
  file the push changes must be the design's (`design.sha256`), a proposal image the proposals
  repository has at that path (`repo_images`: a blobless fetch each push, `git hash-object`
  compared with `ls-tree`; its QR codes checked too), `projects.json`, or the list's files as installed in `/etc/ccs-gate`. A failing file is
  deleted from staging, so it keeps its last good copy; the rest goes live, the push fails, IRC is
  told. `--heartbeat` (a timer): alerts when no push has come for 15 minutes.
- nginx: static files, the security headers, the theme map ([two machines](two-machines.md)).

## The dense parts

Where to slow down: `markdown.awk`'s `hold`/`unhold`; `ccs-receive`'s `decode`, `strip` and `tokens` (entity
decoding by hand, no interval expressions for old mawk); `load_state`'s CSV regex
(`proposals.sh`); `forgejo_prs`' time-zone conversion (`gitlab.sh`).

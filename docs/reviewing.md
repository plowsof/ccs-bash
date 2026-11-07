# Reviewing: what each file does

**To trust the site, review only the web server.** It builds the site itself, and it doesn't
believe the backend: the backend sends only `site-data.json` (each proposal's subaddress index,
dates and funds, the ideas), checked there, and every page is made there from copies the backend
never sends. So the backend, its code and its machine can stay untrusted; a taken-over backend can
stop the site updating, or show wrong totals, not put a foreign address on it. What runs on the
web server, by version, the code to read (about 3,900 lines, its build files included) and what
is installed there by hand: [the web server](web-server.md).

**Why the web server fetches the proposals repository itself.** A proposal's page is mostly its
own text. The gate fetches the repository from the forge over HTTPS and builds each proposal's
page from its file there, with ccs-front-bash's `markdown.awk` (vendored in the gate's image).
So a backend can't write anything into a proposal's page (a proposal that doesn't exist, other
goals, "donate by contacting…", a link to another site). The same copy tells the gate which
proposals exist (a page whose file is gone goes off the site) and each one's merge request (from
GitLab's merge commits). So the trust moves from the backend to the proposals repository, whose
merges are reviewed already, and the one gap is its images, which nothing on the web server
reads: whoever merges a proposal checks them too.

The rest of this page is every file that runs on the live machines, in the order a run uses it,
with what each part checks: the web server's, and the backend's for those who want them too. Left out: the tests, the container build (`container/`), the release tools
(`contrib/release/`) and the design ([ccs-front-hugo](https://github.com/plowsof/ccs-front-hugo),
built offline). Every script is `set -euo pipefail`, `LC_ALL=C` and shellcheck-clean; the awk is
POSIX (mawk, gawk, busybox).

The rule everything serves: every donation address shown, as text, link or QR code, is one of the
wallet's. [The design](design.md) says why it is built this way.

## Backend (no inbound connections)

In Docker, the production setup ([docker](docker.md)), the backend compose runs one service a
stage, each its own container and user, every one read-only, no capabilities, `no-new-privileges`,
no Docker socket: `pull` as `ccs-git`, `ccs-bash` as `ccs`, `backup` as `ccs-send`, `push` as
`ccs-push`, `watch` as `ccs-watch`.

- [`contrib/docker/backend/step`](../contrib/docker/backend/step), each stage's runner (in
  ccs-bash's image): the stages take turns through the
  run folder (each one's `done`, `status`, `at`, its own user's; pipes that wake the next); a run
  every 120 s, sooner once wallet-rpc's `tx-notify` (`ccs-notify`) writes a line on pull's `now`,
  never two starts closer than 30 s; each run's result only `push` writes and `watch` reads.
- [`contrib/ccs`](../contrib/ccs), root's: `ccs status`, `ccs log`, `ccs config:check`, and
  ccs-back's artisan names.

### ccs-bash: proposals, GitLab and the wallet to JSON

Pinned container, read-only, no capabilities; on the internal `wallet` network, which only
wallet-rpc shares.

- [`ccs-back.sh`](../ccs-back.sh): `main` is the run: config, `flock`, a watchdog (`RUN_SECONDS`,
  900: a run that hangs is stopped, its lock with it), proposals, state, wallet checks, totals,
  new proposals' merged MRs, new subaddresses (or a mirror's), funds, never lower, fully funded
  (`record_funded`: a Funding Required proposal's first run at its goal, once, as the state's
  `funded_date`, the feed's), ideas (GitLab down: the last list), images, the JSON.
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
  to from the signed list, they are logged and counted for no proposal.
- `check_never_lower` (`ccs-back.sh`): a proposal's raised total may not go below what the last
  run published (`OUTPUT_DIR/projects.json`): the run stops; `STATE_DIR/allow-lower` lets one through.
- `retired_totals` (`lib/wallet.sh`): the donations to wallets the CCS used before, per proposal
  file, from `STATE_DIR/retired/*.csv` (written by [`contrib/retire-wallet`](../contrib/retire-wallet),
  which asks that wallet which state addresses are its own and records only deposits with
  `MIN_CONFIRMATIONS`; `--again` later, what came since, in `<name>-2.csv`, never one a record of
  that wallet has); a deposit (wallet, txid, subaddress) counted once, whichever files have it;
  every field checked before bash arithmetic (no leading zero, at most 18 digits: bash wraps past
  2^63); no addresses in it. `check_wallet_addresses`: every state subaddress the wallet's, and given to
  the proposal its label names (a swapped state stops the run).
- [`lib/mirror.sh`](../lib/mirror.sh), with `MIRROR_URL` only (a CCS shown beside another that
  runs on the same wallet, as the testnet beside ccs.getmonero.org): `mirror_load` reads the other
  site's `/projects` (16 MB at most); `mirror_assign`, in place of `assign_addresses`, gives a
  proposal the state has no address for the feed's, matched by title and author (and date, when
  the feed has that key twice, told apart by the wallet's labels), only if the wallet says it is
  its own: never index 0, one past the signed list or 100000, or one another proposal has; a
  proposal shown with one address here and another there stops the run. `mirror_hide`: a
  funding-required proposal with no address yet isn't on the site. The totals stay this wallet's
  (and retired wallets'); only a proposal in neither shows the feed's (`historic_totals`).
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

### ccs-front-bash: the JSON and the design to the site (on the web server)

[Its repository](https://github.com/plowsof/ccs-front-bash), its release vendored in the gate's
image (`vendor/ccs-front-bash`) and run there by `ccs-gate-build`, on the JSON `site_from_data`
made of the checked `site-data.json`; reads the design, the JSON, the proposals and the signed
list, writes the site.

- `ccs-front-bash.sh`: `main` copies the design (not `parts/`), fills the lists, tag pages and
  proposal pages into `site.new`, then swaps it in (a failure keeps the last site).
  `check_addresses`: the list's sha256 is its `.pin`'s (else the run stops) and every donation
  address is in the list: a funding-required proposal whose address isn't is left off the site
  (its page, its cards, the counts) and the run exits 3; fills the Verify page. `qr_codes`: one QR
  code per checked address, `qr/<address>.png`: the signed list's own file (`LIST.qr/`, its sum the
  one in `LIST.qr.sha256` that the `.pin` pins; else the run stops; no list, no run);
  ccs-bash makes none. `relative_links`: the data's absolute links made relative,
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
  base58 characters, the QR code its `/qr/<address>.png` from `qr_codes`, else the run stops), milestones, and
  payouts where the design has them.
- `lib/markdown.awk`: a Markdown subset to HTML. Everything is escaped first, and only tags it
  writes itself appear (finished HTML is held as `\001n\002` placeholders, so later steps can't
  touch it; a proposal's own `\001` and `\002` are dropped). Links: `https:`, `#anchor`, or
  site-relative (`/` and a plain character: never `//`, `/\` or an entity, which a browser reads as
  another site). Images: only the proposal's copied ones, any other
  is a link.

### Push, watcher, backup

- [`contrib/ccs-push`](../contrib/ccs-push), the push (`push`, as `ccs-push`): `site-data.json`
  when its sum isn't `accepted`'s, what the gate last took (and once a day, `full`), as it is on
  ssh's stdin to the web server's key, which runs only the gate; else nothing, the heartbeat. `accepted` written only when the gate took it (exit 0).
- [`contrib/ccs-watch`](../contrib/ccs-watch) (`watch`, as `ccs-watch`): the live pages' addresses,
  as one of three browsers through a random proxy (what it fetches, and why:
  [two machines](two-machines.md#watching-the-web-server-the-backend-raises-the-alarm)): `wrong`,
  every address on a page, as the gate's `ccs-check scan` reads it (in the image; without it,
  every 95- or 106-character base58 run), the signed list's or `WATCH_ALLOWED`'s, a
  funding-required proposal's box its own address (ccs-bash's `projects.json`) and its one image
  (the design's `ccs:donate` part) its QR code, the list's file of it; it refetches before it counts, `sighted` keeps the day's sightings.
  After each push and between pushes at random times (the `watch` stage). A wrong page (three
  fetches over 40 s, or a recheck not answered) alerts the second time it is seen within a day;
  so does a page answering anything but 200 three checks in a row; `--run`, three failed runs.
  Its config is read key by key, never sourced.
- [`contrib/migrate/compare-deposits`](../contrib/migrate/compare-deposits), as root, once:
  ccs-back's `deposits` table against the first run's `deposits.csv` (every line of which is
  checked first: it is `ccs`'s file); exits 1 if ccs-back has a deposit the wallet lacks, or
  another amount.
- [`contrib/ccs-backup-receive`](../contrib/ccs-backup-receive), the backup machine's forced
  command: `proposals.csv` (1 MB, its rows' shape) and a retired wallet's file (64 MB) each kept as a
  new dated copy, never overwritten or deleted; a retired wallet only if listed in
  `/etc/ccs-backup/retired-names`, a later version only if it renames proposals one for one;
  `deposits.csv` (64 MB) replaces its one copy only if it has every deposit that copy has, and
  wasn't checked in the future. Every number at most 18 digits. Nothing once the folder holds 256 MB.

## Web server

- [`contrib/ccs-receive`](../contrib/ccs-receive), the push key's forced command, as `ccs-data`,
  one push at a time (`flock`); only `receive` asked (anything else refused); staging emptied, the
  push taken into it (`ccs-check receive`, contrib/ccs-check/push: `site-data.json` alone, 4 MB at
  most, a JSON object, written beside and renamed, else refused and IRC told; refused before it
  without `ccs-check`). Then it
  refuses every push without its pinned list (or with one of no addresses), QR codes' sums
  (`.qr.sha256`, the `.pin`'s `qr` line) and QR codes, `git`, `ccs-gate-build`, a design release
  or `proposals.conf`. Built again only when what it's built from changed (`built-with`, a sum
  of them all), and once a day:
  - `fetch` (bash): the proposals repository, all its history (the last fetch if it can't);
  - `ccs-check data` (contrib/ccs-check/sitedata): `site-data.json` read strictly
    (`encoding/json`, no unknown key), each value of its kind; each index the list's, not 0, one
    proposal's only, the live site's for it (`projects.json`'s addresses: `pins`); an idea's name
    and author plain text (`text`: no markup, no bidi control, no run of 90 that could be an
    address), its link a merge request of the repository. One that fails: nothing goes live,
    IRC told;
  - `ccs-gate-build` ([`contrib/gate-build`](../contrib/gate-build)): the repository's newest
    commit unpacked (`git archive`), each proposal's merge request from the merge commit that
    added it (`merge_requests`, `lib/site-data.sh`), `site_from_data` (ccs-bash's own
    `read_proposals`, `proposal_images`, `site.jq`; each address the list's line of its index; a
    Funding Required proposal without one left off), then the vendored ccs-front-bash with the
    newest design, the list and its QR codes. One that fails: nothing goes live, IRC told;
  - `ccs-check gate` (contrib/ccs-check/gate) over what was built: `ccs-check scan` (one pass):
    every address in pages, JSON and the feed (which may have none) as written (entities
    decoded, a non-ASCII or control character read both as nothing and as a space; in groups split
    by up to three spaces or punctuation, or between elements side by side (the text with its tags
    dropped), by its checksum: `addr`, a budget of checksums and time a file), the JSON as JSON
    too (`ccs-check json`, its strings read the same way); no `data:` image, no NUL byte; pages
    and JSON start with `<`, `[` or `{`; and every `qr/<address>.png` exactly the list's (its line
    in `.qr.sha256`: never made or decoded here);
  - a failing file is left out, so `ccs-check copy --delete` takes its live copy off too, and IRC
    is told; but more than `CCS_GATE_REMOVE` (3) pages leaving at once (failed, or their proposals
    gone), nothing goes live (`allow-remove` lets them, once). `--heartbeat` (the `heartbeat`
    service's loop): no push for 15 minutes.
- In Docker ([the web server in Docker](docker.md#the-web-server-in-docker)): the gate's image runs
  its own sshd on 2223 ([`contrib/docker/web/sshd_config`](../contrib/docker/web/sshd_config): one
  user, `ForceCommand ccs-receive`, keys only, no shell, forwarding or subsystem), as root with
  only `SETUID`, `SETGID`, `SYS_CHROOT`; [`contrib/docker/web/init`](../contrib/docker/web/init)
  writes its host key and passwd once. The backup receiver the same, on 2224, on its own machine.
- Caddy and Tor (`www`, `tor`): static files, the security headers, the theme redirects, the onion ([`Caddyfile`](../contrib/docker/web/Caddyfile), [`torrc`](../contrib/docker/web/torrc), [two machines](two-machines.md)).

## Where an address is checked against the signed list

The rule everything serves, step by step, from a new proposal's subaddress to the visitor's
wallet. The list is the wallet's first 15,000 subaddresses, signed by a Core Team member's own
key; its `.pin` (sha256 and key) is what each machine trusts, installed by hand once
`tools/verify-subaddresses.sh` (ccs-front-bash) has checked who signed it ([the signed list](signed-list.md)).

| Step | Where | What is checked | If not |
|---|---|---|---|
| 1. The wallet is the CCS wallet | `lib/common.sh` `load_config`; `lib/wallet.sh` `check_wallet_addresses` | `WALLET_ADDRESS` (root's config, which ccs-bash can't write) is the wallet's main address; every subaddress in the state is the wallet's at its index | the run stops |
| 2. A new proposal gets a subaddress | `lib/wallet.sh` `assign_addresses` | the wallet's, at the index just after the state's highest (`create_address`, or one the wallet already counts as created after a payment to it, if it has no label), labelled with the proposal, 95 characters (never one already given, and dust sent ahead can't skip the list's end) | the run stops. Not checked against the list here: ccs-bash doesn't read it; step 3 does, before anything is shown |
| 3. Every donation address is on the list | `ccs-check data` (the index the list's); ccs-front-bash `ccs-front-bash.sh` `check_addresses`, in `ccs-gate-build` on the web server | the list is the one its `.pin` names (sha256); every funding-required proposal's address is a line of it | a wrong list: the run stops, no site is made. An address not on it: that proposal is left off the site, the run exits 3 (an address past index 15,000 too: make a longer list) |
| 4. Its QR code is the list's | ccs-front-bash `tools/make-qr.sh`, `verify-subaddresses.sh`; `ccs-front-bash.sh` `qr_codes` | made with the list (`qrencode -s 10 "monero:<address>"`), their sums pinned in its `.pin` (`qr`), each remade when the list is checked; the run copies the address's file, its sum the pinned one; ccs-bash's own QR codes are never used | the run stops |
| 5. The page holds them | ccs-front-bash `lib/pages.jq`, the donation box | the donation box gets that address and that QR code, else the run stops | the run stops |
| 6. The web server's list is the pinned one | `contrib/ccs-receive`, once the push is received, before anything is built | the gate's own copy (installed by hand) is the one its `.pin` names, and so are its QR codes' sums | every push refused, IRC told |
| 7. Every address on every page is on the list | `ccs-check gate`'s `scans` (`ccs-check scan`, `json`) | every 95- or 106-character address in a page or JSON, as written (entities read, a non-ASCII character as nothing and as a space, in groups or across elements by its checksum), is a line of the list or in `allowed`; the feed has none | that file off the site, IRC told |
| 8. Every QR code is of a listed address | `ccs-check gate` (`Run`, `scans`) | every `qr/<address>.png` is that address's file of the list's, byte for byte (its sum in `.qr.sha256`); no `data:` image; never made or decoded | that file off the site |
| 9. Addresses only where the design puts them | the build itself (`ccs-gate-build`) | a page is the design filled by ccs-front-bash on the web server: a donation box's address is the list's line of its proposal's index, never text the backend sent | (by construction) |
| 10. What is live has only the list's addresses | `contrib/ccs-watch` (`wrong`) | the live donation pages (and others at random): every address the list's or allowed, each box its proposal's, its QR code the list's file; a live address not on the list is named in the alert | IRC told |
| 11. The visitor | the Verify page (`parts/verify.html`, filled by `check_addresses`) | the wallet's address and view key, and where they were published: a view-only copy of the wallet says whether an address is its own (`get_address_index`) | the visitor doesn't pay |

Function names, not line numbers, so this stays right as the code moves. Steps 3–9 stop a wrong
address on the web server (whatever the backend sends); 10–11 catch a web server that serves
something else.

## The dense parts

Where to slow down: `markdown.awk`'s `hold`/`unhold` (its escaping decides what a proposal's
page shows: `scan` is the backstop); `ccs-check`'s `sitedata` (`text`'s run of 90 is what keeps
an address out of an idea's name, matched by `noaddress` in `gitlab.sh`) and `scan`'s `entity`
(entity decoding by hand); `merge_requests`' awk (`site-data.sh`); `load_state`'s CSV regex
(`proposals.sh`); `forgejo_prs`' time-zone conversion (`gitlab.sh`).

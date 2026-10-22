<p align="center">
  <img src="logo.svg" width="180" alt="An orange clam seen from the side, eyes peeking out of its open shell, inside a gear">
</p>

# ccs-bash

**A blazingly fast, memory-safe CCS backend. Written in shell.**

- **Blazingly fast:** a full run takes about 3 seconds, once every 2 minutes.
- **Memory safe:** it has no memory. Everything is recomputed on each run, except one CSV file.
- **Fearless concurrency:** `flock -n`.
- **Zero-cost abstractions:** there are no abstractions.
- **A strong type system:** everything is a string, the money too. That's how the amounts stay exact.
- **A friendly compiler:** `shellcheck`.
- **Cargo:** `apt install jq`.

Not a crustacean. A mollusc.

A small replacement for [ccs-back](https://repo.getmonero.org/monero-project/ccs-back),
the backend of the Monero Community Crowdfunding System.
It is a bash script run from cron. It has no web server, database or PHP;
it uses a view-only `monero-wallet-rpc` and either a few Debian packages or a pinned
container image (see [Two ways to run it](#two-ways-to-run-it)).

It writes the files [ccs-front](https://repo.getmonero.org/monero-project/ccs-front) (Jekyll)
reads, `proposals.json` and `completed-proposals.json`, plus `projects.json` for a `/projects` API.

## Security

What an attacker wants is the donation addresses on the website: with a shell on a machine
that writes the JSON or serves the site, they can swap in their own address and collect the
donations. (The wallet is view-only, so the coins already received are not at risk; that
part was never the problem.) ccs-bash is about leaving as few ways in as possible:

- **Nothing to connect to.** ccs-bash is a cron job, not a service: no web server, no open
  port, no database. It only makes outgoing calls, to the wallet and to GitLab.
- **Few, well-kept dependencies.** About ten Debian packages, patched by Debian's security
  team, or the same tools from StageX, built from source (see [Dependencies](docs/setup.md#dependencies)),
  instead of a framework and its package tree. All of ccs-bash is about 700 lines (500
  without comments) you can read in an afternoon.
- **Least privilege.** It runs as a `ccs` user that can only write its state and output
  folders. It refuses to run if it can write its own config (so not as root either).
- **Checks the wallet.** The wallet's main address is pinned in the config (`WALLET_ADDRESS`),
  which only root can change; every subaddress must also match the state file. A swapped
  wallet stops the run instead of getting its addresses published, even if the state file
  (which the `ccs` user can write) was changed to match it.
- **QR codes made fresh.** Every run makes the QR codes again from the addresses and
  never keeps them, so there is no stored image to swap for one with another address
  (which would send donors' money elsewhere while the address shown as text still looks
  right). CI reads qrencode's output back with a real decoder.
- **Untrusted text stays text.** Proposal titles and MR names are HTML-escaped and only
  ever handled as data (no `eval`, every JSON value built by jq), filenames are checked.
- **Can run apart from the website.** ccs-bash and ccs-front can be on
  [separate machines](docs/two-machines.md). Then the wallet machine accepts no
  connections at all: it pushes the JSON to the web server, whose key can only write into
  one folder (`rrsync -wo`). Nothing on the web server can reach the wallet machine, the
  state file (which says which address belongs to which proposal) or read anything back.

What it can't fix: whoever gets a shell on the **web server** can still change the site and
its donation addresses. With the split, a changed JSON is overwritten by the next push
within minutes, but a changed page or template stays until someone notices. So the web
server is now the machine to guard, and the only place left where an attack redirects
donations.

## What a run does

`ccs-back.sh` runs these steps from top to bottom:

1. **Read proposals.** Parse the frontmatter of every `.md` file in the proposals checkout
   (`lib/frontmatter.awk`). Files that don't match the expected format are logged and skipped.
2. **Check the wallet.** Its main address must be `WALLET_ADDRESS`, and it must know every
   subaddress in the state file, at the same index. A restored wallet gets its subaddresses
   re-created; a wrong wallet stops the run.
3. **Count donations.** Per subaddress, txes with at least `MIN_CONFIRMATIONS` are
   `amount-funded`; newer ones, pool included, are `amount-pending`. Donations at a
   subaddress the state file doesn't know stop the run (the state file was lost or changed).
4. **Record new proposals.** For a file seen for the first time, find the merged GitLab MR that
   added it and remember its URL. If it is funding-required, also remember when funding started.
5. **Assign addresses.** Each funding-required (`fr`) proposal without an address gets a new
   subaddress (labelled with the filename), which must come after every index already used.
6. **Fetch ideas.** Open MRs that add a single new proposal file. If GitLab is down,
   the previous list is kept.
7. **Write the JSON files.** QR codes are made fresh, then `lib/site.jq` builds the files,
   which are swapped in atomically.

| File | Does |
|---|---|
| `ccs-back.sh` | entry point, the steps above |
| `lib/common.sh` | logging, config, atomic writes, filename check |
| `lib/frontmatter.awk` | the proposal format parser (and its spec, in the comment at the top) |
| `lib/proposals.sh` | proposals to JSON, the state file |
| `lib/gitlab.sh` | ideas and merged MR lookup |
| `lib/wallet.sh` | wallet RPC, subaddresses, donation totals, QR codes |
| `lib/site.jq` | output format for ccs-front and `/projects` |
| `notify-loop.sh` | optional: runs on new txes as well as every 2 minutes ([setup](docs/setup.md) step 7) |

## State

Everything is recomputed on each run, except `STATE_DIR/proposals.csv`:

```
filename,gitlab_url,subaddr_index,address,funding_required_date
"fund-me.md","https://repo.getmonero.org/.../merge_requests/697",43,"8...","2026-09-08T18:06:19Z"
```

Values with a comma or a quote are quoted (`jq -r '@csv'` writes it that way).
An older `proposals.tsv` converts with `jq -rR 'split("\t") | @csv' proposals.tsv > proposals.csv`.

This file says which subaddress belongs to which proposal, so **back it up**.
The wallet can always be restored from its keys; this file cannot be recreated.

## Two ways to run it

| | A) packages on the host | B) the pinned container |
|---|---|---|
| ccs-bash's tools come from | Debian's packages, as installed today | [StageX](https://stagex.tools) packages, built from source, pinned by digest; busybox and qrencode built from pinned source here |
| The host needs | the packages in [Dependencies](docs/setup.md#dependencies) | Docker (with buildx) and `git` |
| Updates | `apt upgrade` | change the pin and rebuild (see [Changing the pin](docs/image.md#changing-the-pin)) |

Both run the same scripts with the same config and folders, so you can switch between them.
B is the one to use where the supply chain matters: everything in it is built from source,
what runs is exactly what the pins say, and nothing can be installed into it.

## Documentation

- [Setup](docs/setup.md): dependencies, and installing it step by step (A or B)
- [ccs-front on another machine](docs/two-machines.md): the wallet machine pushes, the web server only receives
- [Moving from ccs-back](docs/migrating.md): exporting the state, switching over, what differs
- [The pinned image](docs/image.md): how B is built and checked, changing the pin, releases
- [When something is wrong](docs/troubleshooting.md): what the log lines mean

## To do

- **Check StageX's signatures.** The images are pinned by digest; checking them against the
  signatures StageX's maintainers publish for each release would show the digests are theirs.
- **Watch the live site.** Fetch the published pages and check that every donation address
  (and QR code) on them matches the state file, to notice a changed web server within minutes.

## Tests

```
tests/run.sh             # end-to-end run on tests/fixtures with a fake wallet and GitLab
UPDATE=1 tests/run.sh    # rewrite tests/expected after an intended change, then check the diff
tests/rrsync.sh          # the two-machine rrsync setup, attacked from the wallet machine (docker)
shellcheck -x ccs-back.sh notify-loop.sh lib/*.sh tests/*.sh
```

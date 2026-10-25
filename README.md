<p align="center">
  <img src="logo.svg" width="180" alt="An orange clam seen from the side, eyes peeking out of its open shell, inside a gear">
</p>

# ccs-bash

[![check](https://github.com/plowsof/ccs-bash/actions/workflows/check.yml/badge.svg)](https://github.com/plowsof/ccs-bash/actions/workflows/check.yml) [![release](https://github.com/plowsof/ccs-bash/actions/workflows/release.yml/badge.svg)](https://github.com/plowsof/ccs-bash/actions/workflows/release.yml)

**A blazingly fast, memory-safe CCS backend. Written in shell.**

- **Blazingly fast:** a full run takes about 3 seconds, once every 2 minutes.
- **Memory safe:** it has no memory. Everything is recomputed on each run, except one CSV file.
- **Fearless concurrency:** `flock -n`.
- **Zero-cost abstractions:** there are no abstractions.
- **A strong type system:** everything is a string, the money too. That's how the amounts stay exact.
- **A friendly compiler:** `shellcheck`.
- **Cargo:** `apt install jq`.

Not a crustacean. A mollusc.

A small replacement for [ccs-back](https://repo.getmonero.org/monero-project/ccs-back), the
backend of the Monero Community Crowdfunding System: a bash script run from cron (or a loop
that also runs it when a donation arrives), with a view-only `monero-wallet-rpc`. No web
server, database or PHP. It writes the JSON (`proposals.json`, `completed-proposals.json`, and
`projects.json` for `/projects`, where each proposal also has its `filename` and `gitlab_url`, the
link to its merge request wherever the proposals are) that the site is made from.

## The project

The CCS website is made by three repositories, with no framework, database or JavaScript on
any live machine:

| Repository | What it is |
|---|---|
| **ccs-bash** (this one) | the backend: proposals, the wallet, totals, addresses, as JSON |
| [ccs-front-bash](https://github.com/plowsof/ccs-front-bash) | the site builder: fills the design with ccs-bash's data, every page, in bash |
| [ccs-front-hugo](https://github.com/plowsof/ccs-front-hugo) | the design: the site's HTML and CSS, built once with Hugo, released as a reproducible zip |

<p align="center"><img src="docs/design.svg" width="760" alt="The recommended architecture: the backend makes the site and pushes it to a web server that only serves files"></p>

**Start here: [the handover](docs/handover.md)**, moving ccs.getmonero.org from ccs-back and
Jekyll to this, step by step along the diagram above. Why it's built this way: [the
design](docs/design.md). ccs-bash also still writes the JSON the old Jekyll ccs-front reads.

## Security

An attacker wants the donation addresses on the website: with a shell where the JSON is
written or served, they can swap in their own. (The wallet is view-only; received coins are
not at risk.) So ccs-bash leaves as few ways in as possible:

- **Nothing to connect to.** No server, open port or database; only outgoing calls, to the
  wallet and GitLab.
- **Few dependencies.** About ten Debian packages, or the same tools from
  [StageX](docs/image.md), built from source. All of ccs-bash is about 850 lines (640 without comments): about 610 of bash, the proposal
  parser in awk and the JSON in jq.
- **Least privilege.** Runs as a `ccs` user that can only write its state and output; refuses
  to run if it can write its own config. The wallet has its own user ([setup](docs/setup.md) steps 1–2).
- **Checks the wallet.** Its main address is pinned in the root-owned config
  (`WALLET_ADDRESS`) and every subaddress must match the state file, so a swapped wallet stops
  the run, even if the state file was changed to match.
- **QR codes made fresh** from the addresses on every run, never stored, so there is no image
  to swap. CI decodes them back.
- **Untrusted text stays text.** Titles are HTML-escaped, no `eval`, every JSON value built by
  jq, filenames checked.
- **Can run apart from the website** ([two machines](docs/two-machines.md)): the wallet
  machine accepts no connections and pushes the site to a key that can only write one folder;
  the web server checks every address against the wallet's signed list, and the backend checks
  the live pages are what it pushed.

What it can't fix: a shell on the **web server** can still change the site. ccs-watch then alerts
within minutes (it fetches the live pages, through Tor, and compares them with what was pushed),
and visitors can check any address against the signed list, but that is the machine to guard.

## What a run does

`ccs-back.sh`, top to bottom:

1. **Read proposals:** the frontmatter of every `.md` (`lib/frontmatter.awk`); bad files are logged and skipped.
   Optional `tags:` (a list, any text, e.g. `Abandoned`) go into the JSON as `tags`, escaped.
2. **Check the wallet:** main address is `WALLET_ADDRESS`, every subaddress in the state file
   matches. A restored wallet gets them re-created; a wrong one stops the run.
3. **Count donations** per subaddress: `amount-funded` at `MIN_CONFIRMATIONS`, newer (and pool)
   `amount-pending`. Donations at an unknown subaddress stop the run.
4. **Record new proposals:** the merged MR that added each new file, and when funding started.
5. **Assign addresses:** a new subaddress for each `fr` proposal without one, after every index used.
6. **Fetch ideas:** open MRs that add exactly one new proposal file (editing files doesn't count), and
   besides it only its images, inside an images folder (`images/<its name>/`), whose text reads as a
   proposal (the same parser as step 1): a stray or junk `.md` is not an idea. GitLab down keeps the
   previous list.
7. **Copy images:** a proposal's images are files in the repository, inside an images folder named
   after it (`images/my-proposal/chart.png` for `my-proposal.md`). Those its `.md` shows as
   `![…](images/my-proposal/chart.png)`, real PNG, JPEG or GIF files up to 2 MB, are copied into the
   output (`images/`, listed in `images.json`) for ccs-front-bash to show; any other image stays a link.
   GitLab or Forgejo/Gitea (e.g. git.disroot.org): `REPOSITORY_URL` says which (`ccs.conf.example`).
8. **Write the JSON:** fresh QR codes, `lib/site.jq`, swapped in atomically.

| File | Does |
|---|---|
| `ccs-back.sh` | the steps above |
| `lib/common.sh` | logging, config, atomic writes, filename check |
| `lib/frontmatter.awk` | the proposal format parser, spec at the top |
| `lib/proposals.sh` | proposals to JSON, the state file |
| `lib/gitlab.sh` | ideas, merged MR lookup |
| `lib/wallet.sh` | wallet RPC, subaddresses, totals, QR codes |
| `lib/site.jq` | output for ccs-front and `/projects` |
| `notify-loop.sh` | optional: also run on new txes ([setup](docs/setup.md) step 7) |

## State

All is recomputed each run except `STATE_DIR/proposals.csv` (written by `jq -r '@csv'`):

```
filename,gitlab_url,subaddr_index,address,funding_required_date
"fund-me.md","https://repo.getmonero.org/.../merge_requests/697",43,"8...","2026-09-08T18:06:19Z"
```

It maps proposals to subaddresses and can't be recreated, so **back it up**: each new version
to another machine, which only adds copies ([setup](docs/setup.md#backing-up-the-state)). If it is
lost or wrong, runs stop rather than hand out new addresses ([troubleshooting](docs/troubleshooting.md)).

## Two ways to run it

| | A) packages on the host | B) the pinned container |
|---|---|---|
| Tools from | Debian's packages | [StageX](https://stagex.tools): source-built, pinned, signatures checked ([details](docs/image.md)) |
| Host needs | the [dependencies](docs/setup.md#dependencies) | Docker with buildx, `git`; `gpg` and `jq` to build |
| Updates | `apt upgrade` | [change the pin](docs/image.md#changing-the-pin) and rebuild |

Same scripts, config and folders, so you can switch. B pins everything that runs; A avoids
Docker on the host and gets Debian's security updates automatically.

## Documentation

- [Handover](docs/handover.md): start here, from ccs-back and Jekyll to this, step by step; what you fill in
- [Recommended design](docs/design.md): bash renders the site on the backend, the web server only serves files
- [Setup](docs/setup.md): dependencies, installing step by step, backing up the state
- [Two machines](docs/two-machines.md): the backend pushes, the web server only receives; the gate, the alerts, the theme
- [The pinned image](docs/image.md): how B is built and checked, changing the pin, releases
- [Attesting a release](contrib/release/README.md): rebuild a release, sign what came out into ccs-sigs, as Feather Wallet does
- [When something is wrong](docs/troubleshooting.md): what the log lines mean

## Tests

```
tests/run.sh             # end-to-end on tests/fixtures, fake wallet and GitLab
UPDATE=1 tests/run.sh    # rewrite tests/expected after an intended change
tests/rrsync.sh          # the two-machine setup, attacked from the wallet machine (docker)
shellcheck -x ccs-back.sh notify-loop.sh lib/*.sh tests/*.sh container/*.sh
```

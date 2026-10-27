# When something is wrong

Start from what you see (the symptoms below) or what IRC said ([the alerts](#what-irc-says)).
Every run rebuilds the whole site, so most things fix themselves once their cause is gone; manual
jobs are at the end.

## Where everything is

| Machine | What to look at | Command |
|---|---|---|
| **backend** | every run, every step: errors, warnings, proposals skipped and why | `tail -n 100 /var/log/ccs-bash.log`, `grep -E 'error\|warning\|skipping\|failed' /var/log/ccs-bash.log \| tail -n 30` |
| | the update loop and the wallet | `systemctl status ccs-bash ccs-wallet-rpc`, `journalctl -u ccs-bash -u ccs-wallet-rpc -n 50` |
| | what the site was made from | `/var/lib/ccs/out/*.json` (ccs-bash's JSON), `/var/lib/ccs/www/site/` (the pages pushed) |
| | the state: which proposal has which subaddress | `/var/lib/ccs/state/proposals.csv` (the one file nothing can make again); `deposits.csv` and `ideas.cache` beside it are caches |
| **web server** | the gate: each push, what it held back and why | `journalctl -t ccs-gate -n 50` (and `/var/log/ccs-gate.log` if created) |
| | the live site, and its settings | `/var/lib/ccs-data/` (live), `/etc/ccs-gate/` (the list, `allowed`, the design, `markdown.awk`, `proposals.conf`) |
| **backup machine** | the copies of the state | `ls -l /var/lib/ccs-backup/` (`proposals-<time>.csv`, every version; `deposits.csv`, one copy) |

A run, every 2 minutes and on each donation: pull the proposals → ccs-bash (JSON) → back up the
state → ccs-front-bash (pages) → push, through the gate → ccs-watch compares the live pages. A good
run ends with `ccs-watch: the N pages on https://… and the M other pages and files, are what was pushed`.

## A proposal isn't on the site

1. **Is it in the checkout?** `ls /var/lib/ccs/proposals/<name>.md`. No: not merged yet, or the
   pull failed (the forge down: wait).
2. **Did ccs-bash read it?** `awk -f /opt/ccs-bash/lib/frontmatter.awk /var/lib/ccs/proposals/<name>.md`
   prints one line if it reads, else `skipping <name>.md: <reason>` (also in the log):

   | Reason | Fix (in the proposals repository: the site follows on the next run) |
   |---|---|
   | `missing title` / `author` / `date` / `amount`, `no milestones` | add it to the front matter |
   | `amount is not a number` | a plain number: `85`, `240.12`, `1,500` |
   | `layout must be fr, wip or cp` | `layout: fr` (funding required), `wip` or `cp` |
   | `key <name> appears twice`, multi-line values, `>` or `\|`, anchors | write it plainly: the parser refuses anything YAML and Jekyll could read differently |
   | `no frontmatter between --- lines` | the file must start with `---`, the front matter, `---` |
   | `bad filename`, `filename is not valid UTF-8`, `not a plain file` | rename it: `<plain-name>.md` |
3. **Is it in the JSON?** `jq '.[] | .proposals[] | select(."local-url" | test("<name>"))' /var/lib/ccs/out/proposals.json`.
   In the JSON but not on the site: `grep 'left off the site' /var/log/ccs-bash.log | tail -n 3`
   (its address isn't on the signed list: see [the whole site](#the-whole-site-isnt-updating), `ccs-front-bash`).
   A funding-required one needs a donation address: `grep '"<name>.md"' /var/lib/ccs/state/proposals.csv`
   shows its subaddress. `warning: GitLab lookup failed for new proposal <name>.md, retrying next run`:
   the forge's API is down, it gets its address once it answers.

## A proposal's page isn't updating (old text, old totals)

The gate held it back; its last good copy stays live. On the **web server**,
`journalctl -t ccs-gate -n 50` says why:

| The gate says | Meaning | Fix |
|---|---|---|
| `<page>: <address>` (and IRC: `donation address … is not in the signed list`) | an address on the page isn't one of the wallet's | a proposal quoting another address (a payout address, an example): add it to `/etc/ccs-gate/allowed`, one a line with a `#` comment. Not that: **stop and look**, someone may be trying to show a foreign address |
| `not the text of its proposal as the proposals repository has it` | the page's text isn't what the gate makes of the proposal's file | a merge landing between the backend's pull and the push: gone next run. Lasting: the web server's `markdown.awk` isn't the backend's ccs-front-bash's (install it), or the gate can't fetch the repository (`could not fetch the proposals repository`: its last fetch is used) |
| `a proposal page with no proposal (<name>.md) in the proposals repository` | the gate's copy of the repository doesn't have it yet | as above: the next fetch |
| `not a page of the design as ccs-front-bash fills it`, `a page the design does not have`, `the design has no part or slot` | the page isn't the design's | after a design or ccs-front-bash upgrade: the web server lacks the new design (`/etc/ccs-gate/design/<release>/`, `design.sha256`). Otherwise: **stop and look**, the backend sent something else |
| `an image that is not exactly qrencode's QR code of one address` | a QR code that isn't the wallet's address, drawn as ccs-front-bash draws it | **stop and look** |
| `not the design's (design.sha256)` | a stylesheet, font or icon that isn't the design release's | install the new design's lines on the web server, or **stop and look** |
| `not the proposals repository's images/…` | a proposal image the repository doesn't have at that path | it was changed or removed upstream; the next fetch, or **stop and look** |

The push then exits 7: a failed run; ccs-watch still checks the live pages.

## The totals look stuck, or wrong

Totals come from the wallet. On the **backend**:

```
grep -E 'error|wallet|deposits' /var/log/ccs-bash.log | tail -n 10
rpc() { curl -s --digest -u "$(sed -n 's/^RPC_USER=//p' /etc/ccs/ccs.conf):$(sed -n 's/^RPC_PASSWORD=//p' /etc/ccs/ccs.conf)" \
    "$(sed -n 's/^RPC_URL=//p' /etc/ccs/ccs.conf)" -d "{\"jsonrpc\":\"2.0\",\"id\":0,\"method\":\"$1\",\"params\":${2:-{\}}}"; }
rpc get_height; head -n 1 /var/lib/ccs/state/deposits.csv     # the wallet's height, and the kept deposits'
```

| In the log | Meaning | What to do |
|---|---|---|
| `curl: (7)` / `(22) … 401`, `could not …` around the wallet | wallet-rpc is down, or the login is wrong | `systemctl status ccs-wallet-rpc`; the login is `rpc-login` in `/etc/ccs-wallet/wallet-rpc.conf`, the same as `RPC_USER`/`RPC_PASSWORD` in `/etc/ccs/ccs.conf`. The site keeps its last totals meanwhile |
| `the wallet is at height N, below the H its kept deposits go to: rescanning or restored?` | the wallet knows less than before: it is rescanning (a lost cache, a restore) or its node is behind | wait: the site keeps its last totals, and runs go on by themselves once the wallet is past H. Its node: `daemon-address` in `wallet-rpc.conf` |
| `the wallet lacks N of the deposits kept in deposits.csv` | the daily full check: deposits the file has and the wallet doesn't | a wallet still rescanning (wait, it clears), or a reorg deeper than 30 blocks (rare: check a block explorer). Then: [make deposits.csv again](#make-depositscsv-again) |
| `warning: the wallet knows N deposit(s) below height H that deposits.csv lacked: added` | the daily check found deposits the file missed (a lookahead gap fixed, a rescan) | nothing: they now count |
| `warning: donations at subaddress N, which no proposal was given (no label)` | someone sent to an address of the wallet's that isn't on the site | nothing (it counts for no proposal). Many of them: someone is sending dust |
| `donations at subaddress N, which this wallet gave a proposal but proposals.csv doesn't have` | the state lacks a proposal that has donations: a lost or wrong state file | [restore the state](#restore-the-state) |
| `the wallet's main address is not WALLET_ADDRESS`, `wallet subaddresses do not match proposals.csv` | another wallet is running | the right `wallet-file` in `wallet-rpc.conf`; nothing was written |
| `deposits.csv: not a deposits file`, `a line that isn't a deposit` | the cache is damaged | [make deposits.csv again](#make-depositscsv-again) |
| `would show less raised than before (N proposals: …)` | a proposal's total would go down: a retired wallet's record missing or damaged, a state row cleared, a wallet rescanning | find which (the line names them) and restore it; the site keeps its last totals meanwhile. Meant (a donation that was never real): `runuser -u ccs -- touch /var/lib/ccs/state/allow-lower` lets one run through |
| `retired/<name>.csv: not a retired wallet's file`, `a line that isn't a deposit` | a retired wallet's record is damaged: state, not a cache | copy its newest `retired-<name>-*.csv` back from the backup machine (as [restore the state](#restore-the-state)): the backup keeps a later version only if its deposits are the first version's |
| a proposal funded through an older wallet shows 0 raised | it was renamed: its retired donations are under the old name | rename it in `retired/*.csv` too ([edit the state](#edit-the-state)) |

A donation counts at `MIN_CONFIRMATIONS` (10); a **time-locked** one only once its lock has passed.

## Ideas are missing

| In the log | Meaning |
|---|---|
| `could not fetch ideas from GitLab, keeping the previous list` | the forge is down: the last list stays |
| `not an idea: MR !N's <file> doesn't read as a proposal: <reason>` | the MR's file wouldn't read once merged (the reasons as above): the author fixes it |
| `could not read MR !N` / `could not fetch <file> of MR !N` | that one MR, this run only |
| `N open MRs, only the 100 most recently updated are looked at` | many open MRs (spam?): `IDEAS_MAX` in `ccs.conf` |

An idea is an MR adding exactly one `.md` at the root (and only images in `images/<its name>/`).
A title with a long run of address characters is shortened (`9ZqZqZ…ZqZq`).

## The whole site isn't updating

`grep 'ccs-watch: this run failed' /var/log/ccs-bash.log | tail -n 3` names the steps that failed;
the lines above it say why.

| Step | Common causes |
|---|---|
| `ccs-bash` | the wallet (above); `cannot read config`, `config … is writable by ccs` (it must be root's, 640, group ccs) |
| `ccs-front-bash` | `<file>: no donation address` (a funding-required proposal without one: see the GitLab lookup above); `warning: left off the site: <page>: its donation address … is not one of the wallet's` (that proposal is left off, the rest of the site goes out; an index past the signed list's end: make a longer list, ccs-front-bash's docs/setup.md step 5; else **stop and look**); `no proposal file`, marker errors (`no <!-- /ccs:… -->`, `nothing to fill`): the design and ccs-front-bash aren't releases that go together ([the releases](handover.md#the-releases)) |
| `the push` | the lines above it in the log say which: `ssh: connect … timed out` or `refused` (the web server or its firewall), `Permission denied (publickey)` (the push key, or the web server's `from=`), `Host key verification failed` (the web server's host key changed: check why before trusting it); or the gate refused: on the web server, `journalctl -t ccs-gate -n 20` (`refused the push: …` names what it lacks) |
| `the backup (proposals.csv)` / `the backup (deposits.csv)` | the line above it says why: `ssh: connect … timed out`, `Permission denied` (the backup machine, its key or `from=`); `ccs-backup: … 256 MB already` (its folder is full: look at what is in it, a taken-over backend can fill it); `the new deposits.csv lacks N deposit(s)` (a reorg deeper than 30 blocks, or the wallet rescanning: [make deposits.csv again](#make-depositscsv-again)) |
| `the push (the web server held a file back)` | see [a page isn't updating](#a-proposals-page-isnt-updating-old-text-old-totals) |
| `Unable to find image` / `pull access denied` | the run script starts an image that is gone: it must name an image ID, `--pull never`, with a stopped container on it ([setup](setup.md) step 3) |

## What IRC says

| Message | From | Meaning |
|---|---|---|
| `the backend has failed N runs in a row since …: <steps>` | backend | three or more failed runs: [the whole site isn't updating](#the-whole-site-isnt-updating); once an hour while it lasts |
| `the backend runs again, after N failed runs` | backend | it recovered |
| `the page differs from what was pushed @ <url>`, `donation address … does not match the CCS wallet` | backend (ccs-watch) | the web server serves something the backend didn't push: **stop and look at the web server**, it may be taken over |
| `the page answers HTTP <code>, not what was pushed (N checks in a row)` | backend | one page keeps answering something else (a redirect, an error) while the site answers: the web server's nginx, or worse |
| `<site> could not be fetched (N checks in a row)` | backend | the site is down or unreachable through the watcher's proxy (Tor) |
| `the web server held back a page: donation address … is not in the signed list` / `held back a file: <reason>` | web server | [a page isn't updating](#a-proposals-page-isnt-updating-old-text-old-totals) |
| `the web server refuses every push: <reason>` | web server | the gate lacks something (its list isn't its pin's, no design, no `markdown.awk`, …): fix it on the web server |
| `no push from the backend for N minutes` / `pushes from the backend arrive again` | web server | the backend can't reach it (off, its network, the push key); the backend's own alerts cover a backend that runs but fails |
| `GitLab/Forgejo hasn't answered for over Nh: …` / `answers again` | backend | the proposals' forge is down (or its URL changed): the site keeps its last proposals and Ideas; after `FORGE_HOURS` (`/etc/ccs/alert.conf`, default 6). Check `REPOSITORY_URL` and the checkout's remote by hand |
| `the web server can't fetch the proposals repository since …` / `fetches … again` | web server | the same seen from the gate (or its `proposals.conf` is wrong): pages are checked against its last fetch, so a proposal merged or changed since is held back |

## Doing things by hand

On the backend, as root. **Pause the loop** before changing anything it reads; check one run
before resuming.

| Job | How |
|---|---|
| **Run now** (not waiting 2 minutes) | `touch /var/lib/ccs-notify/new-tx` (it runs within 30 s); watch `tail -f /var/log/ccs-bash.log` |
| **Pause / resume** | `systemctl stop ccs-bash` / `systemctl start ccs-bash` (the site stays as it is; after 15 minutes without a push the web server tells IRC, and again when pushes return: expected) |
| **One run by hand**, while paused | `/usr/local/bin/ccs-bash-update; tail -n 30 /var/log/ccs-bash.log` |
| **Change a proposal's text, title, milestones, status** | in the proposals repository, never on a machine: the next run shows it (and the gate checks it against the repository) |
| **Remove a proposal from the site** | revert or remove its file in the proposals repository; its subaddress stays in the state, never handed out again |

### Edit the state

`proposals.csv`: `"file","merge request link",index,"address","funding since (UTC)"`. Never change
a shown proposal's index or address: donors pay that address.

```
systemctl stop ccs-bash
cp -a /var/lib/ccs/state/proposals.csv /root/proposals.csv.$(date -u +%Y%m%dT%H%M%SZ)
runuser -u ccs -- nano /var/lib/ccs/state/proposals.csv   # as ccs: the file is ccs's
/usr/local/bin/ccs-bash-update; tail -n 30 /var/log/ccs-bash.log
systemctl start ccs-bash
```

Don't restore `deposits.csv`: [make it again](#make-depositscsv-again) from the wallet (the backup's
copy is only a check that it grows). A retired wallet's record lost: its newest
`retired-<name>-*.csv`, into `/var/lib/ccs/state/retired/<name>.csv` (`ccs`, 644).

Typical: a missing merge request link (column 2), a funding date (column 5, `2026-10-25T13:00:00Z`),
an old index recorded as retired ([handover](handover.md#2-ccs-bash-and-its-state-the-backend)).
The next run backs the new version up. `retired/*.csv` (a renamed proposal) is edited the same way.

### Make deposits.csv again

A cache: deleted, the next run makes it again from the wallet (which must be caught up).

```
runuser -u ccs -- mv /var/lib/ccs/state/deposits.csv /var/lib/ccs/state/deposits.csv.old
touch /var/lib/ccs-notify/new-tx; tail -f /var/log/ccs-bash.log
```

After a real shrink (a reorg deeper than 30 blocks), replace the backup machine's copy by hand, as
root (`/var/lib/ccs-backup/deposits.csv`): it only takes one that grows.

### Restore the state

The newest `proposals-<time>.csv` on the backup machine from before it went wrong (a taken-over
backend could have sent bad ones since: compare with `/projects`), copied to the backend, then:

```
systemctl stop ccs-bash
cp -a /var/lib/ccs/state/proposals.csv /root/proposals.csv.$(date -u +%Y%m%dT%H%M%SZ)   # the one it replaces
install -o ccs -g ccs -m 644 proposals-<time>.csv /var/lib/ccs/state/proposals.csv
/usr/local/bin/ccs-bash-update; tail -n 30 /var/log/ccs-bash.log
systemctl start ccs-bash
```

### Go back to the previous release

Pause the loop; put the previous image ID (`docker ps -a --filter name=keep`) in `ccs-bash-run` or
`ccs-front-run`, or swap `/opt/ccs-front-hugo/public` and `public.old`; one run by hand; resume.
The gate allows both designs while both are in `/etc/ccs-gate/design/` and `design.sha256`.

## Don't

- **Edit the live site** (`/var/lib/ccs-data`): the next push replaces it, and ccs-watch alerts.
- **Edit `WALLET_ADDRESS`, the signed list, its pin or `list-signers`** outside the handover's
  steps: everything is checked against them.
- **Run a second update while one runs**: pause the loop first.

## Other

| In the log | Meaning |
|---|---|
| `another run is still going, skipping` | a run took longer than 2 minutes (a slow wallet or forge); harmless once |
| `warning: <file> shows images/…, which isn't in the repository`, `is not a PNG, JPEG or GIF`, `is over … bytes` | that image stays a link |
| `error: <name>: 1 of 2 maintainer signatures` (build) | a StageX pin lacks two trusted signatures. Don't work around it: refresh the [keys](image.md#signatures) if StageX added a maintainer, else wait |

The image has bash and `container/busybox-applets` only; look around with
`docker run --rm -it --entrypoint bash <image ID>` (and `ccs-bash-run`'s `-v`s). Another image ID
than CI's: rebuild with `NO_CACHE=1 container/build.sh`.

# When something is wrong

Start from what you see (the symptoms below) or what IRC said ([the alerts](#what-irc-says)).
Every run rebuilds the whole site, so most things fix themselves once their cause is gone; manual
jobs are at the end.

## Looking

On the backend, as root, `ccs` does what ccs-back's artisan commands did, by the same names and,
where they printed lines, the same lines; `monero:notify` (a rescan from a height) has no
counterpart: every run asks the wallet. Only `proposal:process` changes anything:

| ccs-back | Here | Says |
|---|---|---|
| `php artisan proposal:process` | `ccs proposal:process` | one run by hand: the next run starts at once, its lines |
| `php artisan proposal:update` | `ccs proposal:update` | each open MR looked at, as ccs-back said it: `Idea MR #N 'title': file`, or `Skipping MR #N: why` (merged already, no proposal, or why its file doesn't read) |
| `php artisan generate:addresses` | `ccs generate:addresses [file.md]` | which proposal has which subaddress and address, funding since when |
| `php artisan wallet:notify` | `ccs wallet:notify [N]` | the last N (20) donations, as ccs-back said them: `Donation to "file" address: … amount: … txid: …` (`Unrecognized donation, …` at a subaddress no proposal has); then the funding-required proposals' totals |
| `php artisan deposit:list` | `ccs deposit:list [file.md]` | every deposit as JSON, by ccs-back's table's names (`tx_id`, `amount` in atomic units, `subaddr_index`, `block_received`), and its `wallet` (live, or a retired one's) and `proposal` |
| `laravel.log` | `ccs log [N]` | the errors and warnings of the last N runs (3), each once, with what this page says of it; then the proposal files left out, and why |
| | `ccs status` | the compose (each service and its health), the last run (ok, or the steps that failed), the forge, the backup, the web server, the wallet, the releases |
| | `ccs config:check` | every file the setup needs: there, owned as setup makes it, filled in, agreeing, answering ([the examples](../contrib/examples/backend/README.md)); changes nothing |

It is `/opt/ccs-bash/contrib/ccs` ([setup](setup.md), the backend, step 2 links it as `/usr/local/bin/ccs`): it
reads this page from the same checkout, so its hints are the release's.

## Where everything is

| Machine | What to look at | Command |
|---|---|---|
| **backend** | every run, every step: errors, warnings, proposals skipped and why | `ccs status`, `ccs log` ([looking](#looking)); the whole log: `journalctl -t ccs -n 100` |
| | the update loop and the wallet | `docker compose ps` in `/opt/ccs-bash/contrib/docker/backend`; one service's lines: `docker compose logs -n 50 <service>` |
| | what the site was made from | `/var/lib/ccs/out/*.json` (ccs-bash's JSON), `/var/lib/ccs/www/site/` (the pages pushed) |
| | the state: which proposal has which subaddress | `/var/lib/ccs/state/proposals.csv` (the one file nothing can make again); `deposits.csv` and `ideas.cache` beside it are caches |
| **web server** | the gate: each push, what it built, what it held back and why | `journalctl -t ccs-gate -n 50` (and `/var/log/ccs-gate.log` if created); in Docker `/var/log/ccs-web/ccs-gate.log` |
| | the live site, and its settings | `/var/lib/ccs-data/` (live), `/etc/ccs-gate/` (the list and its QR codes, `allowed`, the design, `proposals.conf`) |
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
   In the JSON but not on the site: `ccs log` (`left off the site`)
   (its address isn't on the signed list: see [the whole site](#the-whole-site-isnt-updating), `ccs-front-bash`).
   A funding-required one needs a donation address: `ccs generate:addresses <name>.md` shows its
   subaddress. `warning: GitLab lookup failed for new proposal <name>.md, retrying next run`:
   the forge's API is down, it gets its address once it answers.

## A proposal's page isn't updating (old text, old totals)

The web server builds the site; a page that fails its checks goes off the site, and a build or
`site-data.json` that fails leaves the live site as it was. On the **web server**,
`journalctl -t ccs-gate -n 50` says why (in Docker: `tail -n 50 /var/log/ccs-web/ccs-gate.log`):

| The gate says | Meaning | Fix |
|---|---|---|
| `<file>: <address>` (and IRC: `donation address … is not in the signed list`) | an address on the page isn't one of the wallet's: in a proposal's own text (the box's is the list's by construction) | a proposal quoting another address (a payout address, an example): add it to `/etc/ccs-gate/allowed`, one a line with a `#` comment; the page comes back on the next build. Not that: **stop and look**, a proposal merged with a foreign address |
| `site-data.json held back (<why>)` | the backend's data isn't as ccs-bash writes it: an index the list hasn't, another than the live site's for that proposal, a proposal the repository hasn't, markup in an idea | `a proposal the repository hasn't`: a merge the gate hasn't fetched yet, gone next push. Another index than the live site's: **stop and look at the backend** (its state changed). Otherwise the backend and gate aren't one release |
| `could not build the site (ccs-gate-build)` | the lines under it say why | after a design upgrade: the design release isn't one this ccs-front-bash fills (the handover's releases table). Otherwise the build's own error: report it |
| `N pages would leave the site at once` | more than 3 pages failed, or their proposals are gone from the repository (a branch emptied or rewritten, `proposals.conf` on the wrong one), or the backend hid Funding Required proposals (no index) | look at the pages it names. Meant (proposals taken out together): `touch /var/lib/ccs-gate/allow-remove` (owned by ccs-data), and the next push lets them go |
| `not the signed list's QR code of that address (its .qr.sha256)`, `not a QR code of the list's` | a file in `/etc/ccs-gate/subaddresses.txt.qr/` isn't the list's | install the list's QR codes again, checked: `sha256sum -c` ([the signed list](signed-list.md)) |
| `too many runs that could be addresses to check`, `its addresses could not be read` | a page made to be slow to check (the largest real page is under 200 kB) | a proposal's text: look at it |
| `could not fetch the proposals repository (proposals.conf): building from the last fetch` | the gate couldn't fetch the repository this push (the forge down, or `proposals.conf` wrong) | a proposal merged or changed since shows once a fetch works; after `FORGE_HOURS`, IRC says so |

The push then exits 1: a failed run (but for a page taken off, which leaves the rest live).

## The totals look stuck, or wrong

Totals come from the wallet. On the **backend**, `ccs status` (the wallet and its height),
`ccs log` (what the last runs said), `ccs deposit:list <name>.md` (every deposit a proposal's
total counts, the retired wallets' too); by hand:

```
rpc() { curl -s --digest -u "$(sed -n 's/^RPC_USER=//p' /etc/ccs/ccs.conf):$(sed -n 's/^RPC_PASSWORD=//p' /etc/ccs/ccs.conf)" \
    "$(sed -n 's/^RPC_URL=//p' /etc/ccs/ccs.conf)" -d "{\"jsonrpc\":\"2.0\",\"id\":0,\"method\":\"$1\",\"params\":${2:-{\}}}"; }
rpc get_height; head -n 1 /var/lib/ccs/state/deposits.csv     # the wallet's height, and the kept deposits'
```

| In the log | Meaning | What to do |
|---|---|---|
| `curl: (7)` / `(22) … 401`, `could not …` around the wallet | wallet-rpc is down, or the login is wrong | `docker compose ps wallet-rpc`, `docker compose logs -n 50 wallet-rpc`; the login is `rpc-login` in `/etc/ccs-wallet/wallet-rpc.conf`, the same as `RPC_USER`/`RPC_PASSWORD` in `/etc/ccs/ccs.conf`. The site keeps its last totals meanwhile |
| `the wallet is at height N, below the H its kept deposits go to: rescanning or restored?` | the wallet knows less than before: it is rescanning (a lost cache, a restore) or its node is behind | wait: the site keeps its last totals, and runs go on by themselves once the wallet is past H. Its node: `daemon-address` in `wallet-rpc.conf` |
| `the wallet lacks N of the deposits kept in deposits.csv` | the daily full check: deposits the file has and the wallet doesn't | a wallet still rescanning (wait, it clears), or a reorg deeper than 30 blocks (rare: check a block explorer). Then: [make deposits.csv again](#make-depositscsv-again) |
| `warning: the wallet knows N deposit(s) below height H that deposits.csv lacked: added` | the daily check found deposits the file missed (a lookahead gap fixed, a rescan) | nothing: they now count |
| `warning: donations at subaddress N, which no proposal was given (no label)` | someone sent to an address of the wallet's that isn't on the site | nothing (it counts for no proposal). Many of them: someone is sending dust |
| `donations at subaddress N, which this wallet gave a proposal but proposals.csv doesn't have` | the state lacks a proposal that has donations: a lost or wrong state file | [restore the state](#restore-the-state) |
| `the wallet's main address is not WALLET_ADDRESS`, `wallet subaddresses do not match proposals.csv` | another wallet is running | the right `wallet-file` in `wallet-rpc.conf`; nothing was written |
| `deposits.csv: not a deposits file`, `a line that isn't a deposit` | the cache is damaged | [make deposits.csv again](#make-depositscsv-again) |
| `would show less raised than before (N proposals: …)` | a proposal's total would go down: a retired wallet's record missing or damaged, a state row cleared, a wallet rescanning | find which (the line names them) and restore it; the site keeps its last totals meanwhile. Meant (a donation that was never real): `runuser -u ccs -- touch /var/lib/ccs/state/allow-lower` lets one run through |
| `retired/<name>.csv: not a retired wallet's file`, `a line that isn't a deposit` | a retired wallet's record is damaged: state, not a cache | copy its first `retired-<name>-<time>.csv` back from the backup machine (as [restore the state](#restore-the-state)), and redo any rename by hand: the backup keeps a later version only if it renames proposals, one for one |
| a proposal funded through an older wallet shows 0 raised | it was renamed: its retired donations are under the old name | rename it in `retired/*.csv` too ([edit the state](#edit-the-state)) |
| a donation to a retired wallet's address (after the switch, or too young then) isn't counted | a record is taken when it is run, not kept up | `retire-wallet --again <name>` ([retiring a wallet](handover.md#retiring-a-wallet), "After") |
| `ccs-backup: retired wallet <name>-2 isn't in /etc/ccs-backup/retired-names` (a failed run) | `--again` wrote a record the backup machine wasn't told of | add the name there, as root on the backup machine |

A donation counts at `MIN_CONFIRMATIONS` (10); a **time-locked** one only once its lock has passed.

## Ideas are missing

`ccs proposal:update`: the Ideas shown, and each open MR looked at and why it is or isn't one.

| In the log | Meaning |
|---|---|
| `could not fetch ideas from GitLab, keeping the previous list` | the forge is down: the last list stays |
| `not an idea: MR !N's <file> doesn't read as a proposal: <reason>` | the MR's file wouldn't read once merged (the reasons as above): the author fixes it |
| `could not read MR !N` / `could not fetch <file> of MR !N` | that one MR, this run only |
| `more than 100 open MRs, only the 100 most recently updated are looked at` | many open MRs (spam?): `IDEAS_MAX` in `ccs.conf` |

An idea is an MR adding exactly one `.md` at the root (and only images in `images/<its name>/`).
A title with a long run of address characters is shortened (`9ZqZqZ…ZqZq`).

## The whole site isn't updating

`ccs status` names the steps the last run failed in; `ccs log` shows the lines that say why
(`journalctl -t ccs | grep 'ccs-watch: this run failed' | tail -n 3`, and the lines above it).

| Step | Common causes |
|---|---|
| `ccs-bash` | the wallet (above); `cannot read config`, `config … is writable by ccs` (it must be root's, 640, group ccs) |
| `ccs-front-bash` | `<file>: no donation address` (a funding-required proposal without one: see the GitLab lookup above); `warning: left off the site: <page>: its donation address … is not one of the wallet's` (that proposal is left off, the rest of the site goes out; an index past the signed list's end: make a longer list ([the signed list](signed-list.md#a-new-list)); else **stop and look**); `no proposal file`, marker errors (`no <!-- /ccs:… -->`, `nothing to fill`): the design and ccs-front-bash aren't releases that go together ([the releases](handover.md#the-releases)) |
| `the push` | the lines above it in the log say which: `ssh: connect … timed out` or `refused` (the web server or its firewall), `Permission denied (publickey)` (the push key, or the web server's `from=`), `Host key verification failed` (the web server's host key changed: check why before trusting it); or the gate refused: on the web server, `journalctl -t ccs-gate -n 20` (`refused the push: …` names what it lacks) |
| `the backup (proposals.csv)` / `the backup (deposits.csv)` | the line above it says why: `ssh: connect … timed out`, `Permission denied` (the backup machine, its key or `from=`); `ccs-backup: … 256 MB already` (its folder is full: look at what is in it, a taken-over backend can fill it); `the new deposits.csv lacks N deposit(s)` (a reorg deeper than 30 blocks, or the wallet rescanning: [make deposits.csv again](#make-depositscsv-again)) |
| `the push (the web server held a file back)` | see [a page isn't updating](#a-proposals-page-isnt-updating-old-text-old-totals); the push's log names each (`ccs-push: held back by the web server: <file>: <why>`), and sends it again next run |
| `ccs-push: not sent (a backslash or control character in its name): <file>` | a file the site has whose name the gate refuses: the rest goes. A proposal's file name: rename it in the proposals repository |
| `Unable to find image` / `pull access denied` | an image `.env` names is gone (a Docker cleanup): build or load that attested ID again ([deploying a set](deploying.md), 2); a stopped container on each image keeps it |

## What IRC says

| Message | From | Meaning |
|---|---|---|
| `the backend has failed N runs in a row since …: <steps>` | backend | three or more failed runs: [the whole site isn't updating](#the-whole-site-isnt-updating); once an hour while it lasts |
| `the backend runs again, after N failed runs` | backend | it recovered |
| `the page differs from what was pushed @ <url>`, `donation address … does not match the CCS wallet`, `the file differs from what was pushed (a page's stylesheet, font or image)` | backend (ccs-watch) | the web server serves something the backend didn't push: **stop and look at the web server**, it may be taken over. Once fixed: a stylesheet, font or image it served is kept a year by visitors' browsers (hashed names, `immutable`): a changed file of the design's needs a new release (new names), and say so on IRC |
| `the page answers HTTP <code>, not what was pushed (N checks in a row)` | backend | one page keeps answering something else (a redirect, an error) while the site answers: the web server's `www` (Caddy: `docker compose logs www`), or worse |
| `<site> could not be fetched (N checks in a row)` | backend | the site is down or unreachable through the watcher's proxy (Tor) |
| `a page that was never pushed answers HTTP <code>, not the pushed 404 page @ <url>` | backend | the web server serves pages the backend never made: **stop and look at the web server**, as for a page that differs |
| `the theme button sends visitors to <where> (HTTP <code>), not to the page @ <url>` | backend | the web server's Caddyfile isn't the image's (a changed config), or the web server is taken over |
| `what was pushed isn't the site the front made (…): the push stage changed it?` | backend | the copy of what was pushed doesn't match the sums the front wrote of the site it made: the push stage (or its client) changed it. **Stop and look at the backend** |
| `test, please ignore @ <site>` | backend | someone ran `ccs-watch --test` |
| `the web server took a page off the site: donation address … is not in the signed list` / `took a file off the site: <reason>` | web server | [a page isn't updating](#a-proposals-page-isnt-updating-old-text-old-totals) |
| `the web server held back the backend's site-data.json: <why>` | web server | the same table: the live site stays as it was |
| `the web server could not build the site from site-data.json` | web server | the same table |
| `the web server would take N pages off the site at once …: none of the new site goes live` | web server | more than 3 (`CCS_GATE_REMOVE`) pages would go: failed, or their proposals gone from the repository just fetched (a branch emptied or rewritten, `proposals.conf` on the wrong one), or hidden. The site stays as it was until a person decides (`allow-remove`, the same table) |
| `the web server refuses every push: <reason>` | web server | the gate lacks something (its list isn't its pin's, no design release, no QR codes, …), or the backend sent other files than `site-data.json` (a backend older than the gate: upgrade it; else **stop and look at the backend**): fix it on the web server |
| `the web server refused a push it could not take: <why>` | web server | the push's tar broke a rule (a link, a path out of the site, a name twice, a file under a page, too large) or didn't arrive whole in 5 minutes. Once, with a network break: the next run sends it again. A link or a path out: no backend's push makes one: **stop and look at the backend** |
| `a push has been checked for over 10 minutes: the pushes after it are refused …` | web server | one check is stuck: `journalctl -t ccs-gate` (in Docker `/var/log/ccs-web/ccs-gate.log`), then restart the gate (`docker compose restart gate` in `/opt/ccs-bash/contrib/docker/web`) |
| `no push from the backend for N minutes` / `pushes from the backend arrive again` | web server | the backend can't reach it (off, its network, the push key); the backend's own alerts cover a backend that runs but fails |
| `GitLab/Forgejo hasn't answered for over Nh: …` / `answers again` | backend | the proposals' forge is down (or its URL changed): the site keeps its last proposals and Ideas; after `FORGE_HOURS` (`/etc/ccs/alert.conf`, default 6). Check `REPOSITORY_URL` and the checkout's remote by hand |
| `the web server can't fetch the proposals repository since …` / `fetches … again` | web server | the same seen from the gate (or its `proposals.conf` is wrong): the site is built from its last fetch, so a proposal merged or changed since doesn't show yet |

## Doing things by hand

On the backend, as root. **Pause the loop** before changing anything it reads; check one run
before resuming. The compose's commands run in `/opt/ccs-bash/contrib/docker/backend`
([docker](docker.md#running-it)).

| Job | How |
|---|---|
| **Run now** (not waiting 2 minutes) | `ccs proposal:process`: one run at once, its lines |
| **Pause / resume** | `docker compose stop pull`, then `ccs status` until no run is going / `docker compose start pull` (the site stays as it is; after 15 minutes without a push the web server tells IRC, and again when pushes return: expected) |
| **One run by hand**, while paused | `ccs proposal:process` (paused, it stays paused) |
| **What happened** | `ccs status`, `ccs log` ([looking](#looking)) |
| **Change a proposal's text, title, milestones, status** | in the proposals repository, never on a machine: the next run shows it (and the gate checks it against the repository) |
| **Remove a proposal from the site** | revert or remove its file in the proposals repository; its subaddress stays in the state, never handed out again. The push can't delete: the gate takes the page (and `images/<name>/`) off the live site itself, at the first push after it fetched the repository without the file (`removed proposals/<name>.html … from the site` in its log). A tag only it had keeps its tag page until it's deleted on the web server (`/var/lib/ccs-data/explore/tag/<tag>/`) |

### Edit the state

`proposals.csv`: `"file","merge request link",index,"address","funding since (UTC)"`. Never change
a shown proposal's index or address: donors pay that address.

```
docker compose stop pull                                  # then ccs status: no run going
cp -a /var/lib/ccs/state/proposals.csv /root/proposals.csv.$(date -u +%Y%m%dT%H%M%SZ)
runuser -u ccs -- nano /var/lib/ccs/state/proposals.csv   # as ccs: the file is ccs's
ccs proposal:process                                      # one run (the loop stays paused): check it
docker compose start pull
```

Don't restore `deposits.csv`: [make it again](#make-depositscsv-again) from the wallet (the backup's
copy is only a check that it grows). A retired wallet's record lost: its first
`retired-<name>-<time>.csv` (the record; later ones only rename proposals, which you redo by hand),
into `/var/lib/ccs/state/retired/<name>.csv` (`ccs`, 644).

Typical: a missing merge request link (column 2), a funding date (column 5, `2026-10-25T13:00:00Z`),
an old index recorded as retired ([handover](handover.md#2-ccs-bash-and-its-state-the-backend)).
The next run backs the new version up. `retired/*.csv` (a renamed proposal) is edited the same way.
A renamed proposal's subaddress gets its new name as its label too (the run stops on one whose
label names another proposal: a swapped state), on the backend, as root (the login through a
pipe, never on the command line):

```
c=/etc/ccs/ccs.conf; v() { grep -m1 "^$1=" "$c" | cut -d= -f2-; }
curl -s --digest -K <(printf 'user = "%s:%s"\n' "$(v RPC_USER)" "$(v RPC_PASSWORD)") "$(v RPC_URL)" -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":"0","method":"label_address","params":{"index":{"major":0,"minor":<index>},"label":"<new name>.md"}}'
```

### Make deposits.csv again

A cache: deleted, the next run makes it again from the wallet (which must be caught up).

```
runuser -u ccs -- mv /var/lib/ccs/state/deposits.csv /var/lib/ccs/state/deposits.csv.old
ccs proposal:process
```

After a real shrink (a reorg deeper than 30 blocks), replace the backup machine's copy by hand, as
root (`/var/lib/ccs-backup/deposits.csv`): it only takes one that grows.

### Restore the state

The newest `proposals-<time>.csv` on the backup machine from before it went wrong (a taken-over
backend could have sent bad ones since: compare it with the live site's `/projects`, which the
gate checked; not the backend's own), and each retired wallet's first `retired-<name>-<time>.csv`,
copied to the backend. On a rebuilt backend, put the live `/projects` in
`/var/lib/ccs/out/projects.json` (as `ccs`) before the first run, so it can't show less raised
than the site did. Then:

```
docker compose stop pull                                  # then ccs status: no run going
cp -a /var/lib/ccs/state/proposals.csv /root/proposals.csv.$(date -u +%Y%m%dT%H%M%SZ)   # the one it replaces
install -o ccs -g ccs -m 644 proposals-<time>.csv /var/lib/ccs/state/proposals.csv
install -o ccs -g ccs -m 644 retired-<name>-<time>.csv /var/lib/ccs/state/retired/<name>.csv   # each, if lost
ccs proposal:process                                      # one run (the loop stays paused): check it
docker compose start pull
```

### Move the proposals to another forge

[The proposals' forge](forge.md#moving-to-another-forge).

### Go back to the previous release

[Deploying a release, going back](deploying.md#going-back): the
previous `.env`, checkout and design from the backup folder made before the deploy; the old
images are still there (their keep containers, `docker ps -a --filter name=keep`). The gate builds
with the newest design in `/etc/ccs-gate/design/`: going back, move the new one out.

## Don't

- **Edit the live site** (`/var/lib/ccs-data`): the next push replaces it, and ccs-watch alerts.
- **Edit `WALLET_ADDRESS`, the signed list, its pin or `list-signers`** outside the handover's
  steps: everything is checked against them.
- **Run a second update while one runs**: pause the loop first.

## Other

| In the log | Meaning |
|---|---|
| `another run is still going, skipping` | a run took longer than 2 minutes (a slow wallet or forge); harmless once |
| `error: the run took over 900s: stopped` | a run hung (a forge or wallet that never answers) and was stopped, its lock with it (`RUN_SECONDS` in `ccs.conf`); the next run starts afresh |
| `warning: MIRROR_URL not answering: no new addresses this run` | a mirror: the other site's `/projects` didn't answer; its proposals keep their addresses, a new one waits |
| `error: MIRROR_URL gives <file> subaddress N, which <other> has here`, `… the wallet's subaddress 0 …`, `MIRROR_URL's answer isn't a list of projects` | a mirror: the other site's feed would give an address this one can't take; that proposal waits (the run stops for a proposal shown here with another address). Look at both sites before anything else |
| `warning: <file> shows images/…, which isn't in the repository`, `is not a PNG, JPEG or GIF`, `is over … bytes` | that image stays a link |
| `error: <name>: 1 of 2 maintainer signatures` (build) | a StageX pin lacks two trusted signatures. Don't work around it: refresh the [keys](image.md#signatures) if StageX added a maintainer, else wait |

The image has bash and `container/busybox-applets` only; look around with
`docker run --rm -it --entrypoint bash <image ID>` (and the compose's volumes). Another image ID
than CI's: rebuild with `NO_CACHE=1 container/build.sh`.

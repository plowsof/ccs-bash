# Handover: running the CCS on ccs-bash

For the maintainer of ccs.getmonero.org, which runs today on ccs-back (PHP and MySQL) and the
Jekyll ccs-front. This is how to move it to the setup below: the steps build it box by box, in
order, then the old site is switched off.

<p align="center"><img src="design.svg" width="900" alt="The setup: the backend (monero-wallet-rpc, ccs-bash, ccs-front-bash) makes the whole site from the design and pushes it to a web server whose gate checks every address against the signed list; ccs-watch checks the live pages and alerts IRC, and the web server alerts when pushes stop; the state is backed up; releases are attested in ccs-sigs"></p>

**What stays the same:** the proposals repository, the CCS wallet and every proposal's
subaddress, the site's address and `/projects`.

**What goes:** PHP, MySQL, Jekyll, Ruby. The public web server runs no code: it receives the
finished site and serves it. Why it is built this way: [the design](design.md). The testnet CCS,
https://ccs.monerodevs.org, is this exact setup, running.

## Before you start

- **Machines:** the **backend** (private, takes no connections: the wallet, ccs-bash,
  ccs-front-bash), the **web server** (public: nginx and the gate), a **backup machine** (any,
  for one small file), and an **offline machine** for making the signed list once.
- **The wallet:** the CCS wallet, view-only. Its address and view key are public: luigi1111
  published them in
  [monero-project/meta #935](https://github.com/monero-project/meta/issues/935#issuecomment-1867257410).
- **A Core Team member** to make and sign the subaddress list (step 4).
- **An IRC bot** for the alerts (step 8).
- **The releases** to install, below.

## The releases

The three repositories are released separately; these versions work together and run the
testnet CCS. A row is added with each release.

| Set | ccs-bash | ccs-front-bash | ccs-front-hugo | Running on |
|---|---|---|---|---|
| 2026-10-25 | v0.2.12 | v0.1.14 | v0.1.12 | testnet ([ccs.monerodevs.org](https://ccs.monerodevs.org)) |
| 2026-10-25 | v0.2.11 | v0.1.13 | v0.1.12 | testnet, before |
| 2026-10-25 | v0.2.11 | v0.1.13 | v0.1.11 | testnet, before |
| 2026-10-24 | v0.2.11 | v0.1.13 | v0.1.10 | testnet, before |
| 2026-10-24 | v0.2.10 | v0.1.12 | v0.1.9 | testnet, before |
| 2026-10-24 | v0.2.9 | v0.1.11 | v0.1.9 | testnet, before |
| 2026-10-24 | v0.2.8 | v0.1.11 | v0.1.9 | testnet, before |
| 2026-10-24 | v0.2.7 | v0.1.10 | v0.1.9 | testnet, before |

Each is reproducible: anyone who builds a tag gets the same image ID or zip sha256, and those who
did sign what they got in [ccs-sigs](https://github.com/plowsof/ccs-sigs) (the box at the top left
of the picture). Before installing, check them: `contrib/release/verify <release>` (two signers who
agree, by default), then that the ID or sha256 you install is the attested one
([contrib/release](../contrib/release/README.md)).

## 1. monerod and monero-wallet-rpc (the backend)

monerod, local or one you trust, and monero-wallet-rpc with the CCS wallet, view-only, as its own
user, on 127.0.0.1: [setup](setup.md) step 1.

The wallet from ccs-back: stop its wallet-rpc (it saves on exit), copy `<name>` and `<name>.keys`
into `/var/lib/ccs/wallet` (owner `ccs-wallet`, mode 600), set `wallet-file`, start the service.
`wallet_info` in `monero-wallet-cli` must say `Watch only`; if it can spend, make a view-only one
instead (`--generate-from-view-key`, with the address, the view key and a restore height from
before the first donation). Amounts come from the wallet's history, so it needs all of it.

## 2. ccs-bash and its state (the backend)

The users, folders, config and proposals checkout, and `ccs-bash-run`, from its pinned image (check
its ID against the releases): [setup](setup.md) steps 2 and 3.

**The state from ccs-back**, so every proposal keeps its subaddress. Back up ccs-back's database
(`mysqldump`) first. `<ccs_db>` is the database (add `-u`/`-p`, or `docker exec <db> mysql ...`);
`ORDER BY id` keeps the `/projects` order. Upstream ccs-back (no funding-required date; proposals
funded after the switch get one):

```
mysql -B -N -e "SELECT filename, IFNULL(gitlab_url, ''), IFNULL(subaddr_index, ''), IFNULL(address, ''), '' FROM projects ORDER BY id" <ccs_db> | jq -rR 'split("\t") | @csv' > /var/lib/ccs/state/proposals.csv
chown ccs:ccs /var/lib/ccs/state/proposals.csv
```

With the `funding_required_date` column (plowsof's fork; stored as UTC):

```
mysql -B -N -e "SELECT filename, IFNULL(gitlab_url, ''), IFNULL(subaddr_index, ''), IFNULL(address, ''), IFNULL(DATE_FORMAT(funding_required_date, '%Y-%m-%dT%H:%i:%sZ'), '') FROM projects ORDER BY id" <ccs_db> | jq -rR 'split("\t") | @csv' > /var/lib/ccs/state/proposals.csv
chown ccs:ccs /var/lib/ccs/state/proposals.csv
```

No jq on the host? The image's: `docker run --rm -i --network none --entrypoint jq ccs-bash -rR 'split("\t") | @csv'`.

Run `ccs-bash-run` once. `donations at subaddress ..., which proposals.csv doesn't have` means the
wallet has donations at indices the export lacks: find out why. Old indices that belong to nothing
(say from before a database reset) can be recorded as retired, never shown or handed out (here 8
and 9):

```
curl -s --digest -u 'ccs:<rpc password>' http://127.0.0.1:18082/json_rpc \
    -d '{"jsonrpc":"2.0","id":0,"method":"get_address","params":{"account_index":0,"address_index":[8,9]}}' \
  | jq -r '.result.addresses[] | ["retired-subaddress-\(.address_index)", "", .address_index, .address, ""] | @csv' \
  >> /var/lib/ccs/state/proposals.csv
```

Then compare its JSON with ccs-back's: it should match, except the QR codes (another encoder) and
the differences listed under [step 10](#10-the-cutover):

```
norm() { jq -S '[.[] | {stage, proposals: [.proposals[] | del(.["donate-qr-code"])] | sort_by(.name)}]' "$1"; }
diff <(norm ccs-back/storage/app/proposals.json) <(norm /var/lib/ccs/out/proposals.json)
```

While ccs-back still runs, don't let both hand out addresses: if a funding-required proposal has
none yet, stop ccs-back's cron first.

## 3. The design (the original)

ccs-front-hugo's release zip, sha256 checked, unpacked on the backend: ccs-front-bash's
[docs/setup.md](https://github.com/plowsof/ccs-front-bash/blob/master/docs/setup.md), step 1.

## 4. The signed subaddress list

Every donation address shown must be one of the wallet's: a list of its first 15,000
subaddresses, checked by the backend each run, by the web server's gate on each push, and on the
site's Verify page by anyone. A **Core Team member** makes it on the offline machine and signs it;
contributors can make it from the same public address and view key and confirm its sha256.
ccs-front-bash's [docs/setup.md](https://github.com/plowsof/ccs-front-bash/blob/master/docs/setup.md),
step 5. Its files go to the backend's `/etc/ccs-front/` here, and to the web server in step 6, by
hand: never pushed, so a taken-over backend can't swap it.

The view key file beside it, `/etc/ccs-front/subaddresses.txt.viewkey` (the Verify page shows it,
with the commands to ask a copy of the wallet about an address):

```
62ad19781466882d8df0ae85743abcc5c8ef81e52e051e7cc56fe3c610d18001
source https://github.com/monero-project/meta/issues/935#issuecomment-1867257410
source-text shared by luigi1111 here
```

## 5. ccs-front-bash and the site (the backend)

ccs-front-bash and `ccs-front-run`, from its pinned image, with the list as its fifth argument:
ccs-front-bash's [docs/setup.md](https://github.com/plowsof/ccs-front-bash/blob/master/docs/setup.md),
steps 2 and 5. It makes `/var/lib/ccs/www/site`, every page, each run.

## 6. The web server: the push, the gate, nginx

[Two machines](two-machines.md), way A: the `ccs-data` account the backend pushes to (write-only,
no deleting), nginx with HTTPS, the cache rule and the theme lines, and **the gate**, which checks every address
in each push, its QR codes included, against the signed list (its files from step 4, and the
`allowed` file), and every other file against the design release's (`design.sha256`), and holds
back any that fails; and the gate's heartbeat timer (step 8).

## 7. The backup machine

The state file, `proposals.csv`, is the one thing that can't be made again. Each new version goes
to an account on the backup machine that can only add copies: [setup](setup.md#backing-up-the-state).

## 8. The alerts (ccs-watch and IRC)

- **The backend watches the web server:** after each push, `ccs-watch` fetches the donation pages
  and every file they use as a visitor's browser would, through Tor and a clearnet proxy, and
  compares them with what was pushed. A page or file that differs, or a backend that stops
  running, is an alert.
- **The web server alerts itself** when its gate holds a page back.
- **The web server notices a silent backend:** each push is the backend's heartbeat, and no push
  for 15 minutes is an alert, which the backend can't send when it is off or cut off
  ([the heartbeat](two-machines.md#the-heartbeat-the-web-server-notices-a-silent-backend)).

Both post one line to the IRC bot's URL (below). [Two
machines](two-machines.md#watching-the-web-server-way-a-the-backend-raises-the-alarm) and "The
gate". `ccs-watch --test https://ccs.getmonero.org` sends one message to check it.

## 9. The update

One run of everything, every 2 minutes and on each new donation ([setup](setup.md) step 7, with
its log rotation from step 6), as root (it only starts each step as that step's own user):

```
#!/bin/sh
# /usr/local/bin/ccs-bash-update (chmod 755)
L=/var/log/ccs-bash.log W=/opt/ccs-bash/contrib/ccs-watch failed=''

# the proposals; GitLab down: give up, not a failed run (the last checkout stays)
timeout -k 5 40 runuser -u ccs-git -- env HOME=/ git -C /var/lib/ccs/proposals pull -q --ff-only

# ccs-bash: totals, addresses, the JSON
ccs-bash-run >> $L 2>&1 || failed="ccs-bash"

# the state, to the backup machine when it changed (it keeps every version); read as ccs, whose
# file it is: root never opens a file another account controls (it could be a link to any file)
S=/var/lib/ccs/state/proposals.csv
sum=$(runuser -u ccs -- sha256sum "$S" | cut -c1-64)
if [ "$sum" != "$(cat /var/lib/ccs/backup-sent 2>/dev/null)" ] \
    && runuser -u ccs -- cat "$S" | timeout -k 5 30 ssh -T -i /root/.ssh/ccs-backup_ed25519 -o BatchMode=yes \
        -o IdentitiesOnly=yes -o ConnectTimeout=15 ccs-backup@<backup machine> >> $L 2>&1; then
    echo "$sum" > /var/lib/ccs/backup-sent
fi

# ccs-front-bash makes the site; it goes to the web server, which must then serve exactly that
if ccs-front-run >> $L 2>&1; then
    if timeout -k 5 120 runuser -u ccs -- rsync -a --delay-updates \
            -e "ssh -p 22 -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=15" \
            /var/lib/ccs/www/site/ ccs-data@<web server>: >> $L 2>&1; then
        runuser -u ccs -- $W https://ccs.getmonero.org /var/lib/ccs/www/site >> $L 2>&1
    else failed="${failed:+$failed, }the push"; fi
else failed="${failed:+$failed, }ccs-front-bash"; fi

# how the run went: three failed runs in a row alert, so a stopped backend can't go unnoticed
runuser -u ccs -- $W --run "${failed:-ok}" >> $L 2>&1
```

`-p 22` is the web server's ssh port, given in full in case the backend's `ssh_config` defaults to
another.

## 10. The cutover

With steps 1–9 running, the new site is complete on the web server before anyone sees it.

1. Check it: every page, the Verify page, a donation address against the list, and the log
   (`/var/log/ccs-bash.log`: each run ends with `ccs-watch: the N pages ... are what was pushed`).
2. Stop ccs-back's cron and its `--tx-notify` script.
3. Point `ccs.getmonero.org`'s DNS at the web server (and get its certificate, step 6).
4. Stop ccs-back, its database and Jekyll. Keep the old machine as it is for a while: going back
   is pointing the DNS at it again and starting its cron.

**Differences from ccs-back** (what may look different, and why):

- **Totals** are recomputed from the wallet each run, so a dropped or reorged tx stops counting.
- **Funded** at `MIN_CONFIRMATIONS`, not at unlock; pending before. Time-locked txes don't count.
- **Amounts:** `1,500` is 1500 (ccs-back: 1.5). Shown as strings with 4 decimals, cut off, not
  rounded; percentages round down (99.99996 of 100 shows `99.9999`, 99%). Sums are exact.
- **Authors:** `0xfffc` stays text (ccs-back made it 65532).
- **Dates:** written-out months (`June 25th, 2021`, `10 August 2021`) and `2021-06-25`; the year
  is kept (ccs-back read `10 August, 2021` as 20:21 today). `02/14/2017` shows no date.
- **Frontmatter** is read as YAML (and Jekyll) reads it: `title: Talks #2` is `Talks`, `'quotes'`
  work. Anything ambiguous (multi-line values, `>`/`|`, escapes, anchors, duplicate keys) skips
  the file with the reason logged. No current proposal does this.
- **`/projects`** only lists proposals whose file still exists.
- **GitLab** MR lists are paginated, so MRs past 50 are seen.
- **Removed:** `/projects/<index>` pages, GitHub and Zcoin support.

## Who can do what

Each job runs as its own account, which can do that job and nothing more. Only you have root.

**The backend:** no port open to the internet; it only connects out (monerod, GitLab, the web
server, the backup machine, the IRC bot, Tor).

| Account | Does | Can't |
|---|---|---|
| root | runs the update every 2 minutes, starting each step as the account below; holds the backup key | |
| `ccs-wallet` | runs monero-wallet-rpc, on 127.0.0.1 only, with a login | spend: the wallet is view-only |
| `ccs-git` | owns the proposals checkout and pulls it | anything else: no shell |
| `ccs` | runs ccs-bash (its container read-only, no capabilities, no new privileges); owns the state and the JSON; holds the push key | write the proposals; log in |
| `ccs-front` | makes the site (its container read-only, no network) | write anything but the site |

**The web server:** 80 and 443 open to everyone; 22 to the backend and you.

| Account | Does | Can't |
|---|---|---|
| `ccs-data` | receives the push: its key (root's file, outside its home) works only from the backend's address and only runs the gate; runs the heartbeat check | delete, write outside the site, get a shell, change its key |
| nginx | serves the files | run code: they are static |

**The backup machine:** 22 to the backend and you.

| Account | Does | Can't |
|---|---|---|
| `ccs-backup` | adds a dated copy of the state: its key only runs `ccs-backup-receive` | read, change or delete a copy |

**The IRC bot's machine:** HTTPS in from the backend and the web server; their alert URLs are its
only password, so keep them in the root-owned files above.

On every machine: SSH by key only (`PasswordAuthentication no` in `/etc/ssh/sshd_config`), and
security updates installed automatically (`unattended-upgrades` on Debian).

## What you fill in

Everything that is yours to set, by machine. Values for ccs.getmonero.org are given where they are
known; `<…>` is yours to choose. Secrets (the wallet and RPC passwords, the alert URLs) live only
in these files, root-owned, never in a repository or on a command line.

**The backend**

| File | Setting | For ccs.getmonero.org | Step |
|---|---|---|---|
| `/etc/ccs-wallet/wallet-rpc.conf` | `wallet-file`, `password` | the CCS wallet, view-only, and its password | 1 |
| | `daemon-address` | a monerod you trust (mainnet: `…:18081`) | 1 |
| | `rpc-bind-port`, `rpc-login` | `18082`, `ccs:<rpc password>` | 1 |
| `/etc/ccs/ccs.conf` | `RPC_URL`, `RPC_USER`, `RPC_PASSWORD` | `http://127.0.0.1:18082/json_rpc`, and `rpc-login`'s user and password | 2 |
| | `WALLET_ADDRESS` | `41hzbgqgkrYijnRVBLzr1KHsYc1iUBBCJYeeT9d3eiYE2PhbohxxwJLZCNVbTzvAMkhtYGF3RQcr2Ea187AJn8af149UG1G` ([meta #935](https://github.com/monero-project/meta/issues/935#issuecomment-1867257410)) | 2 |
| | `REPOSITORY_URL` | `https://repo.getmonero.org/api/v4/projects/54` | 2 |
| | `MIN_CONFIRMATIONS` | `10` | 2 |
| the proposals checkout | its remote | `https://repo.getmonero.org/monero-project/ccs-proposals.git` | 2 |
| `/opt/ccs-front-hugo/public` | the design | the release zip of [the releases](#the-releases), its sha256 checked | 3 |
| `/etc/ccs-front/` | `subaddresses.txt` and its `.asc`, `.key.asc`, `.pin` | made and signed by a Core Team member | 4 |
| | `subaddresses.txt.viewkey` | as in step 4 | 4 |
| `/var/lib/ccs/.ssh/` | `id_ed25519` (the push key), `known_hosts` | the web server's host key, from its `/etc/ssh/ssh_host_ed25519_key.pub` | 6 |
| `/root/.ssh/` | `ccs-backup_ed25519`, `known_hosts` | the backup machine's host key | 7 |
| `/etc/ccs/alert.conf` | `ALERT_URL` | the IRC bot's URL (below) | 8 |
| | `SUBADDRESSES`, `WATCH_PROXY`, `WATCH_THEMES` | `/etc/ccs-front/subaddresses.txt`; `socks5h://127.0.0.1:9050` (Tor) and a clearnet proxy elsewhere; `1` | 8 |
| `/etc/ccs/trusted-signers` | the attesters you trust | their keys' fingerprints, one a line | upgrading |
| `/usr/local/bin/ccs-bash-update` | `<web server>`, `<backup machine>` | their addresses | 9 |

**The web server**

| File | Setting | For ccs.getmonero.org | Step |
|---|---|---|---|
| `/etc/ssh/authorized_keys/ccs-data` | `from=`, the key | the backend's address and its push key, `command="/usr/local/bin/ccs-receive"`; `sshd_config`'s `Match User ccs-data` reads only it | 6 |
| `/etc/ccs-gate/` | `subaddresses.txt` and its `.pin`, `.asc`, `.key.asc` | the same files as the backend's | 6 |
| | `design.sha256` | the design release's files, from its zip (two-machines, "The gate"); `apt install zbar-tools` | 6 |
| | `allowed` | the General Fund, `888tNkZrPN6JsEgekjMnABU4TBzc2Dt29EPAvkRxbANsAnjyPbb3iQ1YBRk1UXcdRsiKc9dhwMVgN5S9cQUiyoogDavup3H`, and any address a proposal's text quotes (the gate's refusal names it) | 6 |
| | `alert.conf` | `ALERT_URL` (the bot), `SITE_URL=https://ccs.getmonero.org` | 8 |
| nginx | `server_name`, the certificate | `ccs.getmonero.org`, from certbot | 6 |

**The backup machine:** the `ccs-backup` account, with the backend's key in
`/etc/ssh/authorized_keys/ccs-backup` (step 7).

**The IRC bot.** Both machines send one line of text by HTTP POST to `ALERT_URL`: an IRC bot that
posts it to the channel (CptHook's `simple` module, `https://<host>/<endpoint>?channel=%23<channel>`;
or wmb, with `ALERT_TARGET` and `ALERT_PASSWORD`). Run it on its own machine, behind HTTPS: the
backend and the web server reach out to it, and nothing reaches the backend.

**Built into the design**, already right for ccs.getmonero.org: its address, the General Fund, the
proposals repository and its "Submit idea" link (ccs-front-hugo's `hugo.toml`). Changing any of
them is a new design release.

**Where the testnet differs** (don't copy these): `testnet=1`, monerod on `28081`, wallet-rpc on
`18182`; `MIN_CONFIRMATIONS=1`; the proposals on Forgejo
(`https://git.disroot.org/api/v1/repos/plowsof/ccs-proposals`); its own wallet and list; the IRC
bot on the backend machine itself (the backend's alerts reach it on 127.0.0.1, the web server's
over HTTPS through that machine's proxy).

## Upgrading

The images are built on the backend itself, from the release's tag, not copied there: the same
commit gives the same image ID, so what you build can be checked. Only the design comes as a file,
the release's zip, checked by its sha256. For each new release, in this order:

1. **Attested first.** Check its attestations in ccs-sigs (`master`; `testnet` for trials), from a
   checkout kept on the backend, counting only the signers you trust (their keys' fingerprints in
   a file of your own, not in ccs-sigs, which anyone can send keys to):
   ```
   git clone -q https://github.com/plowsof/ccs-sigs /opt/ccs-sigs      # once; then: git -C /opt/ccs-sigs pull -q
   cd /opt/ccs-bash && env CCS_SIGS_REPO=/opt/ccs-sigs TRUSTED_KEYS=/etc/ccs/trusted-signers \
       contrib/release/verify ccs-bash-v0.2.11
   ```
   It prints the release's image ID (or zip sha256), how many signers agree, and the commit it was
   built from. It needs two, each signature by the key of the signer whose folder it is in;
   `--min-signers 1` (before the release name) relaxes that, for a release only you or one other
   person have attested. Too few: wait for more, or attest it yourself
   ([contrib/release](../contrib/release/README.md)).
2. **Built from its tag, once the tag is the attested commit.** `git -C /opt/ccs-bash fetch --tags
   && git -C /opt/ccs-bash checkout v0.2.11`, then `git -C /opt/ccs-bash rev-parse HEAD` must be the
   commit `verify` printed (a tag can be moved; build.sh runs as root, and starts a privileged
   BuildKit builder, before any ID can be compared); then `container/build.sh ccs-bash:v0.2.11`
   ([the pinned image](image.md)); the same for ccs-front-bash. Or build on another machine and
   `docker save … | ssh <backend> docker load`: loading runs nothing, and step 3 checks the ID.
   The design: download the zip from its release and `sha256sum` it.
3. **Compared.** The built image ID (`docker image inspect … --format '{{.Id}}'`) and the zip's
   sha256 must be the attested ones, and the release notes'. Anything different: stop, keep what runs.
4. **Switched.** Tag the new image as the one the run scripts use (`ccs-bash`, `ccs-front-bash`);
   unzip the design into a new folder and swap it with `/opt/ccs-front-hugo/public`, between runs.
   Keep the previous images (a stopped container on each, so nothing prunes them) to go back to.
5. **Watched and noted.** The next run fills the site and ccs-watch confirms the pages; then add a
   row to [the releases](#the-releases). If anything else on the backend prunes Docker images, keep
   a stopped container on each image ([troubleshooting](troubleshooting.md)).

# Handover: running the CCS on ccs-bash

For the maintainer of ccs.getmonero.org, which runs today on ccs-back (PHP and MySQL) and the
Jekyll ccs-front. This is how to move it to the setup below: the steps build it box by box, in
order, then the old site is switched off.

<p align="center"><img src="design.svg" width="900" alt="The setup: the backend (monero-wallet-rpc, ccs-bash, ccs-front-bash) makes the whole site from the design and pushes it to a web server whose gate checks every page against the design and the proposals repository, and every address against the signed list; ccs-watch checks the live pages and alerts IRC, and the web server alerts when pushes stop; the state is backed up; releases are attested in ccs-sigs"></p>

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
| 2026-10-26 | v0.2.17 | v0.1.16 | v0.1.17 | testnet ([ccs.monerodevs.org](https://ccs.monerodevs.org)) |
| 2026-10-25 | v0.2.16 | v0.1.16 | v0.1.17 | testnet, before |
| 2026-10-25 | v0.2.15 | v0.1.16 | v0.1.16 | testnet, before |
| 2026-10-25 | v0.2.14 | v0.1.16 | v0.1.15 | testnet, before |
| 2026-10-25 | v0.2.13 | v0.1.16 | v0.1.15 | testnet, before |
| 2026-10-25 | v0.2.13 | v0.1.16 | v0.1.14 | testnet, before |
| 2026-10-25 | v0.2.13 | v0.1.15 | v0.1.13 | testnet, before |
| 2026-10-25 | v0.2.12 | v0.1.14 | v0.1.12 | testnet, before |
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
agree, by default, counting only the attesters whose keys you list in `TRUSTED_KEYS`), then that
the ID or sha256 you install is the attested one
([contrib/release](../contrib/release/README.md)).

## 1. monerod and monero-wallet-rpc (the backend)

monerod, local or one you trust, and monero-wallet-rpc with the CCS wallet, view-only, as its own
user, on 127.0.0.1: [setup](setup.md) step 1.

**Moving the wallet from ccs-back:** copy its two files as they are. `<name>.keys` holds the keys
(encrypted with the wallet's password); `<name>`, the cache, holds everything scanned so far: the
history the totals come from, and every subaddress made. With both, nothing is rescanned and the
first run's totals are already right.

1. **Find them on ccs-back's machine.** ccs-back doesn't set up its wallet-rpc (its `.env` only has
   `RPC_URL`), so the files are wherever that wallet-rpc was started from: its `--wallet-file`
   (both files are named after it), or `--wallet-dir` with the name it opened. Ask the process:

   ```
   grep RPC_URL /var/www/html/ccs-back/.env            # the wallet-rpc's port (the example: 28080)
   ss -ltnp | grep ':28080'                             # the process listening there: pid=…
   tr '\0' ' ' < /proc/<pid>/cmdline; echo               # --wallet-file / --wallet-dir / --config-file
   ls -l /proc/<pid>/cwd                                # a relative path is relative to this
   ```

   With `--config-file`, the path is in that file. In Docker, `docker inspect <container>` shows
   which host folder holds it (`Mounts`).
2. Stop that wallet-rpc (it saves on exit, so the cache is current), then
   `sha256sum <name> <name>.keys`.
3. On the backend, named as `wallet-file` says (`ccs`):

   ```
   install -o ccs-wallet -g ccs-wallet -m 600 <name>      /var/lib/ccs/wallet/ccs
   install -o ccs-wallet -g ccs-wallet -m 600 <name>.keys /var/lib/ccs/wallet/ccs.keys
   sha256sum /var/lib/ccs/wallet/ccs /var/lib/ccs/wallet/ccs.keys   # the same as on ccs-back's
   ```

4. `password` in `wallet-rpc.conf` is that wallet's own password: the old wallet-rpc was given it
   too (`--password`, or a `--password-file`, on its command line or in its config file, step 1).
   Start the service.
5. Check it is the CCS wallet, view-only, and caught up:

   ```
   rpc() { curl -s --digest -u 'ccs:<rpc password>' http://127.0.0.1:18082/json_rpc \
       -d "{\"jsonrpc\":\"2.0\",\"id\":0,\"method\":\"$1\",\"params\":${2:-{\}}}"; }
   rpc get_address | jq -r .result.address                    # WALLET_ADDRESS
   rpc query_key '{"key_type":"spend_key"}' | jq -r .error.message   # "The wallet is watch-only. ..."
   rpc get_height | jq .result.height                         # within a few blocks of monerod's
   ```

   If it can spend, don't use it: make a view-only one (below).
6. Step 2 runs ccs-bash once and compares its JSON with ccs-back's: the totals must match.

Without the cache (only `<name>.keys`), wallet-rpc rescans from the wallet's restore height on
start; without either, make the wallet from the address and view key
(`monero-wallet-cli --generate-from-view-key`, a restore height from before the first donation).
Either way, before it scans, raise the subaddress lookahead past the highest index in
`proposals.csv` (`rpc set_subaddress_lookahead '{"password":"<wallet password>","major_idx":1,"minor_idx":20000}'`): a fresh
wallet looks only 200 past the last subaddress it has seen, and would miss donations beyond a gap;
if it has scanned already, `rpc rescan_blockchain` after raising it. Then compare the totals as in
step 6.

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

Run `ccs-bash-run` once. It labels every subaddress in `proposals.csv` with its proposal's file
(ccs-back left them unlabelled). A log line `warning: donations at subaddress ..., which no
proposal was given (no label)` means the wallet has donations at indices the export lacks, which
no total counts: find out why before going on (after the switch, the same line is a stranger's
donation to an address of the wallet's that isn't on the site, and harmless). Old indices that belong to nothing
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
no deleting), nginx with HTTPS, the security headers, the cache rule and the theme lines, and
**the gate**, which checks every page in each push against the design release's own (its zip
unpacked there, as on the backend; a proposal's text against the proposals repository, which it
fetches itself, with ccs-front-bash's `markdown.awk`), every address, its QR codes included,
against the signed list (its files from step 4, and the `allowed` file), and every other file
against the design release's (`design.sha256`), and holds back any that fails; and the gate's
heartbeat timer (step 8).

## 7. The backup machine

The state file, `proposals.csv`, is the one thing that can't be made again. Each new version goes
to an account on the backup machine that can only add copies: [setup](setup.md#backing-up-the-state).
`deposits.csv` goes there too, one copy that may only grow (the wallet can make it again, but
slowly: a rescan).

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

# the state, to the backup machine when it changed (it keeps every version), and deposits.csv
# (it keeps one copy, which only grows); read as ccs, whose files they are: root never opens a
# file another account controls (it could be a link to any file)
for S in /var/lib/ccs/state/proposals.csv /var/lib/ccs/state/deposits.csv; do
[ -f "$S" ] || continue
sent=/var/lib/ccs/backup-sent-${S##*/}; [ "$S" = /var/lib/ccs/state/proposals.csv ] && sent=/var/lib/ccs/backup-sent
# (deposits.csv: its deposits, not its first line, whose height changes every run)
sum=$(runuser -u ccs -- sed '/^# final /d' "$S" | sha256sum | cut -c1-64)
if [ "$sum" != "$(cat "$sent" 2>/dev/null)" ] \
    && runuser -u ccs -- cat "$S" | timeout -k 5 30 ssh -T -i /root/.ssh/ccs-backup_ed25519 -o BatchMode=yes \
        -o IdentitiesOnly=yes -o ConnectTimeout=15 ccs-backup@<backup machine> >> $L 2>&1; then
    echo "$sum" > "$sent"
fi
done

# ccs-front-bash makes the site; it goes to the web server, which must then serve exactly that.
ccs-front-run >> $L 2>&1 || failed="${failed:+$failed, }ccs-front-bash"
# Pushed every run, the last good site if none was made: the push is this machine's heartbeat,
# so the web server's alarm only sounds when this machine can't reach it (its own alerts cover
# a failed run). The push exits 7 when the gate held a file back but the rest went live: a failed
# run, and the live pages are still checked (a web server that lies must not hide behind it)
rc=0
timeout -k 5 120 runuser -u ccs -- rsync -a --delay-updates \
    -e "ssh -p 22 -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=15" \
    /var/lib/ccs/www/site/ ccs-data@<web server>: >> $L 2>&1 || rc=$?
[ "$rc" = 7 ] && failed="${failed:+$failed, }the push (the web server held a file back)"
[ "$rc" = 0 ] || [ "$rc" = 7 ] || failed="${failed:+$failed, }the push"
if [ "$rc" = 0 ] || [ "$rc" = 7 ]; then
    runuser -u ccs -- $W https://ccs.getmonero.org /var/lib/ccs/www/site >> $L 2>&1
fi

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

- **Totals** come from the wallet: its deposits 30 blocks deep kept in `deposits.csv` (a cache: the
  wallet's, made again when deleted), and newer ones asked for each run; once a day everything is
  compared with the wallet. A wallet that knows less than before (rescanning, restored, a reorg
  deeper than 30 blocks) stops the run: the site keeps its last totals, never lower ones.
- **Funded** at `MIN_CONFIRMATIONS`, not at unlock; pending before. A time-locked tx counts once its
  lock has passed, whenever that is (ccs-back only if it unlocked within 50 blocks of its newest
  deposit), and not at all before, not even as pending.
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
| `ccs-backup` | adds a dated copy of the state, and keeps one copy of `deposits.csv` that only grows: its key works only from the backend's address and only runs `ccs-backup-receive` | read, change or delete a copy of the state; take a deposit out of `deposits.csv` |

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
| | `SUBADDRESSES`, `WATCH_PROXY`, `WATCH_THEMES`, `WATCH_SAMPLE` | `/etc/ccs-front/subaddresses.txt`; `socks5h://127.0.0.1:9050` (Tor) and a clearnet proxy elsewhere; `1`; `10` (other pages checked each run, at random) | 8 |
| `/etc/ccs/trusted-signers` | the attesters you trust | their keys' fingerprints, one a line | upgrading |
| `/usr/local/bin/ccs-bash-run`, `ccs-front-run` | the image they run | its ID, `--pull never`, the attested one of [the releases](#the-releases) | 2, 5, upgrading |
| `/usr/local/bin/ccs-bash-update` | `<web server>`, `<backup machine>` | their addresses | 9 |

**The web server**

| File | Setting | For ccs.getmonero.org | Step |
|---|---|---|---|
| `/etc/ssh/authorized_keys/ccs-data` | `from=`, the key | the backend's address and its push key, `command="/usr/local/bin/ccs-receive"`; `sshd_config`'s `Match User ccs-data` reads only it | 6 |
| `/etc/ccs-gate/` | `subaddresses.txt` and its `.pin`, `.asc`, `.key.asc` | the same files as the backend's | 6 |
| | `design.sha256` | the design release's files, from its zip (two-machines, "The gate"); `apt install zbar-tools` | 6 |
| | `design/<release>/` | the design's release zip, unpacked (the same as the backend's); `design.sha256` from it | 6 |
| | `markdown.awk` | `lib/markdown.awk` of the ccs-front-bash release the backend runs | 6 |
| | `proposals.conf` | `PROPOSALS_GIT=https://repo.getmonero.org/monero-project/ccs-proposals.git`, `PROPOSALS_BRANCH=master` (and `LINK_HOSTS`, other forges a proposal's merge request link may be on) | 6 |
| | `subaddresses.txt.viewkey` | the same as the backend's (the Verify page is then checked word for word) | 6 |
| | `allowed` | the General Fund, `888tNkZrPN6JsEgekjMnABU4TBzc2Dt29EPAvkRxbANsAnjyPbb3iQ1YBRk1UXcdRsiKc9dhwMVgN5S9cQUiyoogDavup3H`, and any address a proposal's text quotes (the gate's refusal names it) | 6 |
| | `alert.conf` | `ALERT_URL` (the bot), `SITE_URL=https://ccs.getmonero.org` | 8 |
| nginx | `server_name`, the certificate | `ccs.getmonero.org`, from certbot | 6 |
| | `snippets/ccs-headers.conf` | the security headers, as in two-machines (A+ on securityheaders.com) | 6 |

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
(`https://git.disroot.org/api/v1/repos/plowsof/ccs-proposals`; the gate's `proposals.conf`:
`PROPOSALS_GIT=https://git.disroot.org/plowsof/ccs-proposals.git`, `LINK_HOSTS=repo.getmonero.org`,
where the older proposals' merge requests are); its own wallet and list; the IRC
bot on the backend machine itself (the backend's alerts reach it on 127.0.0.1, the web server's
over HTTPS through that machine's proxy); and a Forgejo Actions runner on the backend, for every
repository of its owner on disroot, the testnet proposals' pre-parser among them: anyone opening a
pull request there starts a job on the wallet's machine (master's script, in an unprivileged
container with no Docker socket and no route to the wallet's RPC). A risk the testnet takes; the
CCS's backend runs nothing but the CCS.

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
4. **Switched.** First the web server, so its gate allows the new pages: a new design, unpacked
   beside the old in `/etc/ccs-gate/design/` and its lines added to `design.sha256`; a new
   ccs-front-bash whose `lib/markdown.awk` changed, that file beside the old as
   `/etc/ccs-gate/markdown-<release>.awk` ([two machines](two-machines.md), "The gate"). Then
   put the new image's ID in the run scripts (`ccs-bash-run`, `ccs-front-run`: they run an image
   by its ID, `--pull never`, so no cleanup can take it from under them) and create a stopped
   container on it (`docker create --name ccs-bash-keep --network none <ID>`, the old one renamed);
   unzip the design into a new folder and swap it with `/opt/ccs-front-hugo/public`, between runs.
   Keep the previous images (their stopped containers) to go back to.
5. **Watched and noted.** The next run fills the site and ccs-watch confirms the pages; then add a
   row to [the releases](#the-releases). If anything else on the backend prunes Docker images, keep
   a stopped container on each image ([troubleshooting](troubleshooting.md)).

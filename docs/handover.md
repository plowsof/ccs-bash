# Handover: running the CCS on ccs-bash

For the maintainer of ccs.getmonero.org (today: ccs-back, PHP and MySQL, and the Jekyll
ccs-front). The steps build the setup below box by box; then the old site is switched off.

<p align="center"><img src="design.svg" width="900" alt="The setup: the backend (monero-wallet-rpc, ccs-bash, ccs-front-bash) makes the whole site from the design and pushes it to a web server whose gate checks every page against the design and the proposals repository, and every address against the signed list; ccs-watch checks the live pages and alerts IRC, and the web server alerts when pushes stop; the state is backed up; releases are attested in ccs-sigs"></p>

**Stays:** the proposals repository, the CCS wallet and every proposal's subaddress, the site's
address and `/projects`. **Goes:** PHP, MySQL, Jekyll, Ruby; the web server runs no code. Why:
[the design](design.md). The testnet CCS, https://ccs.monerodevs.org, is this setup, running.

## Before you start

- **Machines:** the **backend** (private, no inbound connections), the **web server** (public),
  a **backup machine** (any), and an **offline machine** for the signed list.
- **The wallet**, view-only. Its address and view key are public: luigi1111 published them in
  [monero-project/meta #935](https://github.com/monero-project/meta/issues/935#issuecomment-1867257410).
- **A Core Team member** to make and sign the subaddress list (step 4), and **an IRC bot** (step 8).

## The releases

The three repositories release separately; this set works together and runs the testnet. Each
new set replaces the row (earlier sets: this file's history, and ccs-sigs).

| Set | ccs-bash | ccs-front-bash | ccs-front-hugo | Running on |
|---|---|---|---|---|
| 2026-10-26 | v0.2.20 | v0.1.18 | v0.1.18 | testnet ([ccs.monerodevs.org](https://ccs.monerodevs.org)) |

Each is reproducible, and attested in [ccs-sigs](https://github.com/plowsof/ccs-sigs) by those who
rebuilt it. Install only what `contrib/release/verify` confirms ([upgrading](#upgrading)).

## 1. monerod and monero-wallet-rpc (the backend)

monerod (local, or one you trust) and monero-wallet-rpc with the CCS wallet, view-only, its own
user, on 127.0.0.1: [setup](setup.md) step 1.

**Moving the wallet from ccs-back:** copy its two files as they are: `<name>.keys` (the keys,
encrypted with the wallet's password) and `<name>` (the cache: every transfer and subaddress so
far, so nothing is rescanned).

1. **Find them.** They are wherever ccs-back's wallet-rpc was started (`--wallet-file`, or
   `--wallet-dir` and a name). Ask the process:
   ```
   grep RPC_URL /var/www/html/ccs-back/.env            # its port (the example: 28080)
   ss -ltnp | grep ':28080'                             # the process: pid=…
   tr '\0' ' ' < /proc/<pid>/cmdline; echo               # --wallet-file / --wallet-dir / --config-file
   ls -l /proc/<pid>/cwd                                # a relative path is relative to this
   ```
   With `--config-file`, the path is in that file; in Docker, `docker inspect` shows the host folder.
2. Stop that wallet-rpc (it saves on exit), then `sha256sum <name> <name>.keys`.
3. On the backend:
   ```
   install -o ccs-wallet -g ccs-wallet -m 600 <name>      /var/lib/ccs/wallet/ccs
   install -o ccs-wallet -g ccs-wallet -m 600 <name>.keys /var/lib/ccs/wallet/ccs.keys
   sha256sum /var/lib/ccs/wallet/ccs /var/lib/ccs/wallet/ccs.keys   # the same as on ccs-back's
   ```
4. `password` in `wallet-rpc.conf` is the wallet's own (the old wallet-rpc's `--password` or
   `--password-file`). Start the service, and check:
   ```
   rpc() { curl -s --digest -u 'ccs:<rpc password>' http://127.0.0.1:18082/json_rpc \
       -d "{\"jsonrpc\":\"2.0\",\"id\":0,\"method\":\"$1\",\"params\":${2:-{\}}}"; }
   rpc get_address | jq -r .result.address                    # WALLET_ADDRESS
   rpc query_key '{"key_type":"spend_key"}' | jq -r .error.message   # "The wallet is watch-only. ..."
   rpc get_height | jq .result.height                         # within a few blocks of monerod's
   ```
   A wallet that can spend: don't use it; make a view-only one.

Without the cache, wallet-rpc rescans from the restore height; without either file, make the
wallet from the address and view key (`monero-wallet-cli --generate-from-view-key`, a restore
height before the first donation). Before it scans, raise the subaddress lookahead past the
highest index in `proposals.csv`, or it misses donations beyond a gap of 200:
`rpc set_subaddress_lookahead '{"password":"<wallet password>","major_idx":1,"minor_idx":20000}'`
(already scanned: `rpc rescan_blockchain` after).

## 2. ccs-bash and its state (the backend)

The users, folders, config, proposals checkout and `ccs-bash-run`: [setup](setup.md) steps 2–3.

From ccs-back, only the `projects` table moves: which proposal has which subaddress, the one thing
nothing can make again. The donations come from the wallet (step 1); ccs-back's `deposits` table
is only checked against them. With ccs-back's cron stopped (so they don't both hand out
addresses), as root:

```
MYSQL='mysql --defaults-extra-file=/root/ccs-back.cnf' \
    /opt/ccs-bash/contrib/migrate/export-ccs-back <ccs_db> /root/ccs-export /var/www/html/ccs-back
install -o ccs -g ccs -m 644 /root/ccs-export/proposals.csv /var/lib/ccs/state/proposals.csv
```

(`/root/ccs-back.cnf`, mode 600: `[client]` with `user=` and `password=`, so the password isn't on a
command line; `docker exec -i <db> mysql …` works too.) It only reads, and checks what it writes.

**Older wallets.** The CCS has used more than one wallet (CCS1, then CCS2); ccs-back keeps the
older ones' donations in its database, ccs-bash doesn't read it. Record each older wallet from a
synced view-only copy of it ([retiring a wallet](#retiring-a-wallet), step 2, with that copy's
wallet-rpc as `RPC_URL`). For an address no wallet you have claims (an older wallet whose view key
is gone), record its donations from ccs-back's own table instead:

```
runuser -u ccs -- /opt/ccs-bash/contrib/migrate/retire-from-ccs-back ccs0 /etc/ccs/ccs.conf /root/ccs-export
```

(It refuses an index two of ccs-back's proposals share: then that wallet's view key is needed.)
No total may go down: ccs-bash stops a run that would show less raised than before, and
`check-migration` says NOT OK for any proposal below ccs-back's.

Then `ccs-bash-run` once, and check before going on (it says OK or NOT OK for each):

```
/opt/ccs-bash/contrib/migrate/check-migration /root/ccs-export
```

It checks the wallet, every subaddress, the state, the log, every deposit against ccs-back's
(`compare-deposits`: only the wallet's may be extra, each listed with why), and lists what each
proposal shows that differs from ccs-back, which must be one of [step 10](#10-the-cutover)'s
differences. Donations at indices the export lacks (`which no proposal was given`): find out why;
old ones that belong to nothing (from before a database reset, say) are recorded as retired (here
8 and 9):

```
rpc get_address '{"account_index":0,"address_index":[8,9]}' \
  | jq -r '.result.addresses[] | ["retired-subaddress-\(.address_index)", "", .address_index, .address, ""] | @csv' \
  | runuser -u ccs -- tee -a /var/lib/ccs/state/proposals.csv
```

## 3. The design

ccs-front-hugo's release zip, sha256 checked, unpacked on the backend: ccs-front-bash's
[setup](https://github.com/plowsof/ccs-front-bash/blob/master/docs/setup.md), step 1.

## 4. The signed subaddress list

Every donation address shown must be one of the live wallet's first 15,000 subaddresses, a list
checked by the backend and the web server. Each wallet's is in this repository, in
`subaddresses/<wallet>/` (the mainnet's: [`subaddresses/ccs2/`](../subaddresses/ccs2/)), with its
signature, key, `.pin`, `list-signers` and view key file. In full: ccs-front-bash's
[setup](https://github.com/plowsof/ccs-front-bash/blob/master/docs/setup.md), step 5. In short:

1. **Made** by a Core Team member on the offline machine (`tools/make-subaddresses.sh`) from the
   wallet's address and view key; line 0 is `WALLET_ADDRESS`.
2. **Signed with their own key**, as the Monero repository publishes it (`utils/gpg_keys/`):
   binaryFate `81AC591FE9C4B65C5806AFC3F0AF4D462A0BDF92` or luigi1111
   `8777AB8F778EE89487A2F8E7F4ACA0183641E010`
   (`SIGNING_KEY=<fingerprint> tools/sign-subaddresses.sh subaddresses.txt`).
3. **Published and reproduced:** the signer posts its sha256 and fingerprint on meta #935; two
   contributors make it themselves from the same public data and post the same sha256.
4. **Checked, then installed** in `/etc/ccs-front/` (root, 644): the four files, and
   `list-signers` (the two fingerprints above). It must say OK:
   `tools/verify-subaddresses.sh /etc/ccs-front/subaddresses.txt /etc/ccs-front/list-signers <WALLET_ADDRESS>`.
5. The same files go to the web server **by hand** (step 6), never pushed.

From then on, each machine trusts the `.pin`; changing it, or `list-signers`, needs root there
([where each address is checked](reviewing.md#where-an-address-is-checked-against-the-signed-list)).
Beside it, `subaddresses.txt.viewkey`, for the Verify page:

```
62ad19781466882d8df0ae85743abcc5c8ef81e52e051e7cc56fe3c610d18001
source https://github.com/monero-project/meta/issues/935#issuecomment-1867257410
source-text shared by luigi1111 here
```

## 5. ccs-front-bash (the backend)

`ccs-front-run`, from its pinned image, with the list as its fifth argument: ccs-front-bash's
[setup](https://github.com/plowsof/ccs-front-bash/blob/master/docs/setup.md), steps 2 and 5. It
makes `/var/lib/ccs/www/site` each run.

## 6. The web server

[Two machines](two-machines.md): the write-only push account, nginx with HTTPS and its headers,
and the gate (its design, `markdown.awk`, the list's files, `allowed`, `proposals.conf`).

## 7. The backup machine

[Setup](setup.md#backing-up-the-state): an account that can only add copies of the state.

## 8. The alerts

ccs-watch on the backend (the live pages are what was pushed; three failed runs), the gate on the
web server (a held-back page; no push for 15 minutes): both post one line to the IRC bot's URL
([two machines](two-machines.md#watching-the-web-server-the-backend-raises-the-alarm)).
`ccs-watch --test https://ccs.getmonero.org` sends one message to check it.

## 9. The update

One run of everything, every 2 minutes and on each new donation ([setup](setup.md) step 5, with
its log rotation from step 4), as root (it only starts each step as that step's own user):

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
# (and each retired wallet's file, state like proposals.csv: "Retiring a wallet")
for S in /var/lib/ccs/state/proposals.csv /var/lib/ccs/state/deposits.csv /var/lib/ccs/state/retired/*.csv; do
[ -f "$S" ] || continue
sent=/var/lib/ccs/backup-sent-${S##*/}; [ "$S" = /var/lib/ccs/state/proposals.csv ] && sent=/var/lib/ccs/backup-sent
case $S in */retired/*) sent=/var/lib/ccs/backup-sent-retired-${S##*/} ;; esac
# (deposits.csv: its deposits, not its first line, whose height changes every run)
sum=$(runuser -u ccs -- sed '/^# final /d' "$S" | sha256sum | cut -c1-64)
if [ "$sum" != "$(cat "$sent" 2>/dev/null)" ]; then
    # a backup that doesn't go through is a failed run: three in a row tell IRC (the backup
    # machine down, its folder full, a deposits.csv it refuses)
    if runuser -u ccs -- cat "$S" | timeout -k 5 30 ssh -T -i /root/.ssh/ccs-backup_ed25519 -o BatchMode=yes \
        -o IdentitiesOnly=yes -o ConnectTimeout=15 ccs-backup@<backup machine> >> $L 2>&1; then
        echo "$sum" > "$sent"
    else
        failed="${failed:+$failed, }the backup (${S##*/})"
    fi
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

1. Check every page, the Verify page, an address against the list, and the log (each run ends
   with `ccs-watch: the N pages ... are what was pushed`).
2. Stop ccs-back's cron and its `--tx-notify` script.
3. Point `ccs.getmonero.org`'s DNS at the web server (its certificate: step 6).
4. Stop ccs-back, its database and Jekyll; keep the machine for a while (going back: the DNS, and
   its cron).

**Differences from ccs-back:**

- **Totals** come from the wallet, never lower than before: a wallet that knows less (rescanning,
  restored, a reorg deeper than 30 blocks) stops the run, and the site keeps its last totals.
- **Funded** at `MIN_CONFIRMATIONS`, pending before. A time-locked tx counts once its lock has
  passed (ccs-back: only within 50 blocks of its newest deposit), not even as pending before.
- **Amounts:** `1,500` is 1500 (ccs-back: 1.5); 4 decimals, cut off, not rounded; percentages
  round down; sums exact.
- **Authors:** `0xfffc` stays text (ccs-back: 65532).
- **Dates:** written-out months and `2021-06-25`, the year kept (ccs-back read `10 August, 2021`
  as 20:21 today); `02/14/2017` shows none.
- **Front matter** is read as YAML reads it (`title: Talks #2` is `Talks`); anything ambiguous
  skips the file, with the reason logged. No current proposal does.
- **`/projects`** lists only proposals whose file exists. **GitLab** MR lists are paginated (past 50).
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

**Root on the backend and on the web server: not one key.** Each machine checks the other (the gate
the backend's pushes, ccs-watch the web server's pages); whoever has root on both can get past both,
leaving only visitors who check an address in a view-only wallet. So log in to each with its own
SSH key, ideally on its own device (a hardware key), and if you can, let a second person hold the
web server's root and install its list and design.

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
| `/etc/ccs-front/` | `subaddresses.txt` and its `.asc`, `.key.asc`, `.pin` | made by a Core Team member, signed with their own key (binaryFate's or luigi1111's), checked with `tools/verify-subaddresses.sh` | 4 |
| | `list-signers` | `81AC591FE9C4B65C5806AFC3F0AF4D462A0BDF92  # binaryFate` and `8777AB8F778EE89487A2F8E7F4ACA0183641E010  # luigi1111`, from the Monero repository's `utils/gpg_keys/` | 4 |
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
| | `proposals.conf` | `PROPOSALS_GIT=https://repo.getmonero.org/monero-project/ccs-proposals.git`, `PROPOSALS_BRANCH=master` (and `LINK_HOSTS`, other repositories a proposal's merge request link may be in, as host/path) | 6 |
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
`PROPOSALS_GIT=https://git.disroot.org/plowsof/ccs-proposals.git`, `LINK_HOSTS=repo.getmonero.org/monero-project/ccs-proposals`,
where the older proposals' merge requests are); its own wallet and list; the IRC
bot on the backend machine itself (the backend's alerts reach it on 127.0.0.1, the web server's
over HTTPS through that machine's proxy); and a Forgejo Actions runner on the backend, for every
repository of its owner on disroot, the testnet proposals' pre-parser among them: anyone opening a
pull request there starts a job on the wallet's machine (master's script, in an unprivileged
container with no Docker socket and no route to the wallet's RPC). A risk the testnet takes; the
CCS's backend runs nothing but the CCS. The testnet also shows the real CCS's totals: a local
patch of `lib/wallet.sh` adds each proposal's real raised amount and count, as numbers only
(`STATE_DIR/historic.tsv`), to what its testnet wallet receives; every address it shows is the
testnet wallet's. Its alerts go to `#montero-ccs-emojis`.

## Retiring a wallet

When the CCS moves to a new wallet (CCS2 to CCS3), the old one's donations keep counting: recorded
once, by proposal, in `STATE_DIR/retired/<name>.csv` (no addresses; backed up, every version), and
added to the new wallet's each run. Funding-required proposals get new addresses.

1. **Take its addresses off the site** and let it go quiet (nothing in the pool or under
   `MIN_CONFIRMATIONS`: the script refuses until then). `systemctl stop ccs-bash`.
2. **Record it**, as ccs (another wallet-rpc than the config's: its `RPC_URL`, and
   `RETIRE_RPC_USER`/`RETIRE_RPC_PASSWORD` for its login):
   ```
   runuser -u ccs -- /opt/ccs-bash/contrib/retire-wallet ccs2 /etc/ccs/ccs.conf [RPC_URL]
   ```
   It writes `retired/ccs2.csv`, clears those proposals' index and address in `proposals.csv` (the
   old file kept beside it) and, for the live wallet, moves `deposits.csv` aside.
3. **The new wallet:** its files and `wallet-rpc.conf` (step 1), `WALLET_ADDRESS` (step 2), and
   **its list**: made and signed as in step 4, added as `subaddresses/<new wallet>/`, and installed
   on both machines in place of the old one's (`/etc/ccs-front/`, `/etc/ccs-gate/`: every address
   shown from then on is the new wallet's). On the backup machine, as root, move the old
   `deposits.csv` aside (it only takes one with every deposit it has).
4. **One run by hand**, then `systemctl start ccs-bash`: the same totals, new addresses.

A proposal renamed later keeps its retired donations only if it is renamed in `retired/*.csv` too
([edit the state](troubleshooting.md#edit-the-state)).

## Upgrading

Images are built on the backend from the release's tag (the same commit gives the same ID, so it
can be checked); the design comes as its zip, checked by sha256. For each release:

1. **Attested.** From a ccs-sigs checkout on the backend, counting only signers you trust (their
   fingerprints in a file of yours, not in ccs-sigs, which anyone can send keys to):
   ```
   git clone -q https://github.com/plowsof/ccs-sigs /opt/ccs-sigs      # once; then: git -C /opt/ccs-sigs pull -q
   cd /opt/ccs-bash && env CCS_SIGS_REPO=/opt/ccs-sigs TRUSTED_KEYS=/etc/ccs/trusted-signers \
       contrib/release/verify ccs-bash-v0.2.18
   ```
   It prints the image ID (or zip sha256), how many signers agree (two by default;
   `--min-signers 1` relaxes it), and the commit. Too few: wait, or attest it yourself
   ([contrib/release](../contrib/release/README.md)).
2. **Built from its tag**, once `git -C /opt/ccs-bash rev-parse HEAD` after `fetch --tags` and
   `checkout v0.2.18` is the commit `verify` printed (a tag can move, and the build runs as root):
   `container/build.sh ccs-bash:v0.2.18` ([the pinned image](image.md)); the same for
   ccs-front-bash. (`contrib/release/build` doesn't keep the image: it is for attesting.) Or build
   elsewhere and `docker save … | ssh <backend> docker load`. The design: its zip, `sha256sum`.
   A build that stops with `sources has files that are not in sources.lock`: a source an older
   release needed is still in `container/sources/` (a download cache, not in git); move it aside.
3. **Compared:** the image ID and the zip's sha256 must be the attested ones. Any other: stop.
4. **Switched**, web server first, so its gate allows the new pages: a new design unpacked beside
   the old in `/etc/ccs-gate/design/` with its lines added to `design.sha256`; a changed
   `markdown.awk` beside the old as `/etc/ccs-gate/markdown-<release>.awk`. Then the new image IDs in
   `ccs-bash-run` and `ccs-front-run` (by ID, `--pull never`, so no cleanup can remove them), a
   stopped container on each (`docker create --name ccs-bash-keep --network none <ID>`, the old one
   renamed: what to go back to), and the design unzipped and swapped with
   `/opt/ccs-front-hugo/public` between runs.
5. **Watched:** the next run fills the site and ccs-watch confirms it; put the new set in
   [the releases](#the-releases).

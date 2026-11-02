# Handover: running the CCS on ccs-bash

For the maintainer of ccs.getmonero.org (today: ccs-back, PHP and MySQL, and the Jekyll
ccs-front). The steps build the setup below box by box; then the old site is switched off.

<p align="center"><img src="design.svg" width="900" alt="The setup: the backend (monero-wallet-rpc, ccs-bash, ccs-front-bash) makes the whole site from the design and pushes it to a web server whose gate checks every page against the design and the proposals repository, and every address against the signed list; ccs-watch checks the live pages and alerts IRC, and the web server alerts when pushes stop; the state is backed up; releases are attested in ccs-sigs"></p>

**Stays:** the proposals repository, the CCS wallet and every proposal's subaddress, the site's
address and `/projects`. **Goes:** PHP, MySQL, Jekyll, Ruby; the web server runs no code. Why:
[the design](design.md). The testnet CCS, https://ccs.monerodevs.org, is this setup, running
([where it differs](testnet.md)).

**The setup is Docker** on each machine: the backend compose and the web server compose
([docker](docker.md)), each stage its own container, user and secret, every image pinned by its
attested ID. That is what production runs, and what these steps build. (The host setup without
Docker, [setup](setup.md), does the same with systemd and root's script; it is kept for those who
can't run Docker, not recommended.)

**Only looking after it?** `ccs` on the backend does what ccs-back's artisan commands did, by
the same names (`ccs proposal:process`, `ccs wallet:notify`...), and `ccs status`, `ccs log`:
[troubleshooting, Looking](troubleshooting.md#looking). **Setting it up:** the files to fill
in, filled in already as far as they are public, are in
[contrib/examples/backend](../contrib/examples/backend/README.md); `ccs config:check` says what is
still missing or wrong ([what you fill in](#what-you-fill-in)).

## Before you start

- **Machines:** the **backend** (private, no inbound connections), the **web server** (public),
  a **backup machine** (any but the web server), and an **offline machine** for the signed list.
- **The wallet**, view-only. Its address and view key are public: luigi1111 published them in
  [monero-project/meta #935](https://github.com/monero-project/meta/issues/935#issuecomment-1867257410).
- **A Core Team member** to make and sign the subaddress list (step 4), and **an IRC bot** (step 8).
- **How you yourselves get in:** each machine's admin ssh behind a VPN or an allowlist, and a
  way back in without ssh: [admin access](admin-access.md).

## The releases

The three repositories release separately; this set works together and runs the testnet. Each
new set replaces the row (earlier sets: this file's history, and ccs-sigs).

| Set | ccs-bash | ccs-front-bash | ccs-front-hugo | Running on |
|---|---|---|---|---|
| 2026-11-01 | v0.2.40 | v0.1.25 | v0.1.29 | [ccs.monerodevs.org](https://ccs.monerodevs.org), in mirror mode, with its onion and its feed: the backend compose (without `compose.host.yml`) and the web server compose (its gate still v0.2.40's, before `ccs-check`). **Not attested:** each machine built the images from the tags and checked their IDs against the release notes; the last attested set is v0.2.39 / v0.1.24 / v0.1.28 (throwaway-39) |

Each is reproducible, and attested in [ccs-sigs](https://github.com/plowsof/ccs-sigs) by those who
rebuilt it: on the testnet so far by one throwaway key a set (one person; the CCS's should be two
or more people). Install only what `contrib/release/verify` confirms ([upgrading](#upgrading)),
and keep `trusted-signers` to the people you trust now (an old key whose secret wasn't really
destroyed could attest anything).

## 1. monerod and monero-wallet-rpc (the backend)

monerod (local, or one you trust) and monero-wallet-rpc with the CCS wallet, view-only: the
compose's `wallet-rpc`, on a network only ccs-bash is on ([docker](docker.md)).

**monerod.** On the backend itself, or another machine you run: the wallet asks it for every
block, so it must be one you trust (a node that lies can hide donations, not invent spendable
ones). The compose expects it at `daemon-address` in `wallet-rpc.conf`, reached from the
wallet's container over its `monerod` network, which goes out like any container's. So monerod
must listen where a container can reach it, **not on 127.0.0.1 only**: inside a container,
127.0.0.1 is the container itself.

- **Its restricted RPC for the wallet** (`--rpc-restricted-bind-ip`, `--rpc-restricted-bind-port
  18089`): a view-only wallet syncs from it as from any public node, and it can't stop, ban or
  reconfigure monerod. Keep the unrestricted RPC on 127.0.0.1, for you.
- **On the backend itself:** the containers reach the host as `host.docker.internal` (the
  compose maps it to the host's bridge address, `host-gateway`), so
  `daemon-address=host.docker.internal:18089`, with monerod's restricted RPC on `0.0.0.0` (or the
  bridge's address, `172.17.0.1`, when 18089 shouldn't be public). ufw's default denies the
  containers too: `ufw allow from 172.16.0.0/12 to any port 18089 proto tcp`.
- **On another machine:** `daemon-address=<it>:18089`, its firewall open to the backend.
- A firewall's rate limits on 18089 (a public node's flood rules) count the wallet's container
  as any client: a few connections a sync, well under them, but a flood that trips a global
  limit slows the wallet too.

`ccs config:check` says when `daemon-address` is one the wallet's container can't reach. The same
goes for ccs-watch's proxies (`WATCH_PROXY`, [the alerts](#8-the-alerts)): Tor on the backend
listens on the bridge's address, for the compose's networks only, and starts after Docker (the
address exists once Docker does):

```
# /etc/tor/torrc
SocksPort 127.0.0.1:9050
SocksPort 172.17.0.1:9050
SocksPolicy accept 127.0.0.0/8
SocksPolicy accept 172.16.0.0/12
SocksPolicy reject *
# systemctl edit tor@default: [Unit] After=docker.service; then systemctl reload tor@default
ufw allow from 172.16.0.0/12 to any port 9050 proto tcp
```

and `WATCH_PROXY=socks5h://host.docker.internal:9050` (an `ssh -D` clearnet proxy the same way:
`-D 172.17.0.1:1080`; a `SocksPolicy` covers every `SocksPort`, hence 127.0.0.1 accepted too).
The bot is on a third machine, reached by its address; a bot on this one by its public HTTPS
address (as the web server reaches it), not 127.0.0.1.

[`compose.host.yml`](../contrib/docker/backend/compose.host.yml) (the wallet, ccs-bash and the
watch on the host's network, as the testnet has it) is for a host where these can't move off
127.0.0.1. It costs more than the wallet's port: ccs-bash and the watch, which read what the forge,
a mirror's feed and the web server send, then reach everything listening on the host's 127.0.0.1
([docker](docker.md#a-host-whose-monerod-is-on-its-own-127001)).

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
   `--password-file`). Start the service, and check (in Docker, its RPC isn't on the host:
   `ccs config:check` asks the same through ccs-bash's container):
   ```
   rpc() { curl -s --digest -u 'ccs:<rpc password>' http://127.0.0.1:18082/json_rpc \
       -d "{\"jsonrpc\":\"2.0\",\"id\":0,\"method\":\"$1\",\"params\":${2:-{\}}}"; }
   rpc get_address | jq -r .result.address                    # WALLET_ADDRESS
   rpc query_key '{"key_type":"spend_key"}' | jq -r .error.message   # "The wallet is watch-only. ..."
   rpc get_height | jq .result.height                         # within a few blocks of monerod's
   ```
   A wallet that can spend: don't use it; make a view-only one.

Without the cache, wallet-rpc rescans from the restore height; without either file, make the
wallet from the address and view key (`monero-wallet-cli --generate-from-view-key`, which asks
for each in turn, or wallet-rpc's `generate_from_keys` with `address`, `viewkey`, `password` and
`restore_height`), the restore height before the first donation. **Once it has caught up, the smallest lookahead:**
`rpc set_subaddress_lookahead '{"password":"<wallet password>","major_idx":1,"minor_idx":1}'`
(kept in the wallet's keys file). Moving from ccs-back, `compare-deposits` (step 2) shows whether
the wallet found every deposit ccs-back had.

Why 1, not more: a payment to a subaddress within the lookahead makes the wallet create every one
up to it, and look a lookahead further, so a small lookahead keeps how many subaddresses the
wallet makes small; 1 is enough, as ccs-bash creates a proposal's subaddress before showing it.
What it doesn't bound (measured on regtest, `tests/regtest.sh`): a wallet made from its keys
keeps the default table it was made with (200 subaddresses deep in account 0), whatever `set_subaddress_lookahead`
says afterwards, so it still sees payments up to 200 past the last one; and every payment, even
one piconero to a proposal's own address, adds about 0.5 KB to the wallet's cache. Nothing in the
wallet limits that: only the fee each payment costs (a known monero limit, not abused so far).
ccs-bash keeps the list from being used up (a new proposal gets the index after the state's
highest), and counts nothing paid to a subaddress before it was handed out, not the cache.

## 2. ccs-bash and its state (the backend)

The users, folders, config, proposals checkout and the images: [docker](docker.md), with
[setup](setup.md) step 2's users, folders and `ccs.conf`.

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
signature, key, `.pin` and view key file (not `list-signers`: you write that from the fingerprints
in step 2, so a forged folder can't bring its own). In full: ccs-front-bash's
[setup](https://github.com/plowsof/ccs-front-bash/blob/master/docs/setup.md), step 5. The three
scripts are **ccs-front-bash's** (its `tools/`, not this repository's), run from a checkout of it:
[`make-subaddresses.sh`](https://github.com/plowsof/ccs-front-bash/blob/0c6d294918b344b27e6fc0999c4f75fe86294189/tools/make-subaddresses.sh),
[`sign-subaddresses.sh`](https://github.com/plowsof/ccs-front-bash/blob/0c6d294918b344b27e6fc0999c4f75fe86294189/tools/sign-subaddresses.sh) and
[`verify-subaddresses.sh`](https://github.com/plowsof/ccs-front-bash/blob/0c6d294918b344b27e6fc0999c4f75fe86294189/tools/verify-subaddresses.sh) (v0.1.21's). In short:

1. **Made** by a Core Team member on the offline machine from the wallet's address and view key,
   which it asks for (an offline `monero-wallet-rpc` makes them in a view-only copy it deletes
   after; no spend key, no daemon): `tools/make-subaddresses.sh <path to monero-wallet-rpc> 15000
   subaddresses.txt`. Line 0 is `WALLET_ADDRESS`.
2. **Signed with their own key**, as the Monero repository publishes it (`utils/gpg_keys/`):
   binaryFate `81AC591FE9C4B65C5806AFC3F0AF4D462A0BDF92` or luigi1111
   `8777AB8F778EE89487A2F8E7F4ACA0183641E010`
   (`SIGNING_KEY=<fingerprint> tools/sign-subaddresses.sh subaddresses.txt`).
3. **Published and reproduced:** the signer posts its sha256 and fingerprint on meta #935; two
   contributors make it themselves from the same public data and post the same sha256.
4. **Checked, then installed** in `/etc/ccs-front/` (root, 644): the four files, and
   `list-signers` (the two fingerprints above). It must say OK:
   `SIGNER_KEYS=<the signer's key from the Monero repository's utils/gpg_keys/> tools/verify-subaddresses.sh /etc/ccs-front/subaddresses.txt /etc/ccs-front/list-signers <WALLET_ADDRESS>`
   (without `SIGNER_KEYS` it uses the key that came with the list, which may predate a revocation).
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

The compose's `front` ([docker](docker.md)), from ccs-front-bash's pinned image, with the list
(ccs-front-bash's [setup](https://github.com/plowsof/ccs-front-bash/blob/master/docs/setup.md),
step 5). It makes `/var/lib/ccs/www/site` each run. The design's release in
`/opt/ccs-front-hugo/VERSION`, for `ccs status`: `echo "<release> <zip sha256>" > /opt/ccs-front-hugo/VERSION`.

## 6. The web server

[Two machines](two-machines.md): the write-only push account, nginx with HTTPS and its headers,
and the gate's files (its design, `markdown.awk`, the list's files, `allowed`, `proposals.conf`);
then the gate in Docker ([the web server in Docker](docker.md#the-web-server-in-docker)).

## 7. The backup machine

[Setup](setup.md#backing-up-the-state): an account that can only add copies of the state; its
receiver in Docker, the web server compose's `backup` profile ([docker](docker.md#the-web-server-in-docker)).

## 8. The alerts

ccs-watch on the backend (the live pages are what was pushed; three failed runs), the gate on the
web server (a held-back page; no push for 15 minutes): both post one line to the IRC bot's URL
([two machines](two-machines.md#watching-the-web-server-the-backend-raises-the-alarm); every
line and what to do: [troubleshooting](troubleshooting.md#what-irc-says)).
`ccs-watch --test https://ccs.getmonero.org` sends one message to check it.

## 9. The update

The backend compose ([docker](docker.md)) runs one update every 2 minutes and on each new
donation, each stage its own container and user: the proposals pulled, ccs-bash, the backup,
ccs-front-bash, the push to the web server's gate, ccs-watch (and its checks between pushes, at
random times). With the IDs and the web server and backup machine in `.env`:

```
cd /opt/ccs-bash/contrib/docker/backend && docker compose up -d
ccs status                      # each service healthy, the last run: every stage ok, the push pushed
ccs config:check                # nothing failing
```

(The host setup, without Docker, runs the same as one script: [setup](setup.md#the-update-script-the-host-setup).)

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
server, the backup machine, the IRC bot, Tor; a mirror: the site it mirrors).

In Docker ([docker](docker.md)) each account is its stage's container's (read-only, no
capabilities, no new privileges, only its own folders); on the host, root runs the update and
starts each step as its account.

| Account | Does | Can't |
|---|---|---|
| root | the host setup: runs the update every 2 minutes, starting each step as the account below; holds the backup key. In Docker: none of it (each stage runs itself) | |
| `ccs-wallet` | runs monero-wallet-rpc, with a login: on 127.0.0.1, or in Docker on the network only ccs-bash is on | spend: the wallet is view-only |
| `ccs-git` | owns the proposals checkout and pulls it | anything else: no shell |
| `ccs` | runs ccs-bash; owns the state and the JSON (the host setup: holds the push key too) | write the proposals; log in |
| `ccs-front` | makes the site (no network) | write anything but the site |
| `ccs-push` (Docker) | holds the push key; pushes the site; owns the copy of what was pushed and each run's result | write the state or the site |
| `ccs-send` (Docker) | holds the backup key; sends the state when it changes | write the state |
| `ccs-watch` (Docker; the host setup: `ccs`) | runs ccs-watch: reads alert.conf, owns its counters | write the state, the site or what was pushed |

**The web server:** 80 and 443 open to everyone; 22 to you; to the backend, 22 (the host setup)
or 2223, the gate's own sshd (Docker, [the web server in Docker](docker.md#the-web-server-in-docker)).

| Account | Does | Can't |
|---|---|---|
| `ccs-data` | receives the push: its key (root's file, outside its home) works only from the backend's address and only runs the gate; runs the heartbeat check | delete, write outside the site, get a shell, change its key |
| nginx | serves the files | run code: they are static |

**The backup machine:** 22 to you; to the backend, 22 (the host setup) or 2224, the backup
receiver's own sshd (Docker).

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
in these files, root-owned, never in a repository or on a command line. The backend's files are
in [contrib/examples/backend](../contrib/examples/backend/README.md) at their paths, filled in
with what is below; `ccs config:check` checks them (there, owned as setup makes them, filled in,
agreeing, answering) and changes nothing.

**The backend** (in Docker, [docker](docker.md); the host setup's differences are marked)

| File | Setting | For ccs.getmonero.org | Step |
|---|---|---|---|
| `/etc/ccs-wallet/wallet-rpc.conf` | `wallet-file`, `password` | the CCS wallet, view-only, and its password | 1 |
| | `daemon-address` | a monerod you trust (mainnet: `…:18081`) | 1 |
| | `rpc-bind-port`, `rpc-login` | `18082`, `ccs:<rpc password>` | 1 |
| `/etc/ccs/ccs.conf` | `RPC_URL`, `RPC_USER`, `RPC_PASSWORD` | `http://wallet-rpc:18082/json_rpc` (the host setup, or `compose.host.yml`: `http://127.0.0.1:18082/json_rpc`), and `rpc-login`'s user and password | 2 |
| | `WALLET_ADDRESS` | `41hzbgqgkrYijnRVBLzr1KHsYc1iUBBCJYeeT9d3eiYE2PhbohxxwJLZCNVbTzvAMkhtYGF3RQcr2Ea187AJn8af149UG1G` ([meta #935](https://github.com/monero-project/meta/issues/935#issuecomment-1867257410)) | 2 |
| | `REPOSITORY_URL` | `https://repo.getmonero.org/api/v4/projects/54` | 2 |
| | `MIN_CONFIRMATIONS` | `10` | 2 |
| the proposals checkout | its remote | `https://repo.getmonero.org/monero-project/ccs-proposals.git` | 2 |
| `/opt/ccs-front-hugo/public` | the design | the release zip of [the releases](#the-releases), its sha256 checked | 3 |
| `/etc/ccs-front/` | `subaddresses.txt` and its `.asc`, `.key.asc`, `.pin` | made by a Core Team member, signed with their own key (binaryFate's or luigi1111's), checked with `tools/verify-subaddresses.sh` | 4 |
| | `list-signers` | `81AC591FE9C4B65C5806AFC3F0AF4D462A0BDF92  # binaryFate` and `8777AB8F778EE89487A2F8E7F4ACA0183641E010  # luigi1111`, from the Monero repository's `utils/gpg_keys/` | 4 |
| | `subaddresses.txt.viewkey` | as in step 4 | 4 |
| `/etc/ccs/push/` (the host setup: `/var/lib/ccs/.ssh/`) | `id_ed25519` (the push key), `known_hosts` | the web server's host key: in Docker its gate's (`/etc/ccs-gate/ssh/ssh_host_ed25519_key.pub` there, as `[<web server>]:2223 ssh-ed25519 …`); the host setup, its `/etc/ssh/ssh_host_ed25519_key.pub`; `ccs-push` (the host setup: `ccs`), 600 | 6 |
| `/etc/ccs/backup/` (the host setup: `/root/.ssh/`) | `id_ed25519` (the host setup: `ccs-backup_ed25519`), `known_hosts` | the backup key, the backup machine's host key (in Docker its receiver's, as `[<backup machine>]:2224 ssh-ed25519 …`); `ccs-send` (the host setup: root), 600 | 7 |
| `/etc/ccs/alert.conf` | `ALERT_URL` | the IRC bot's URL (below) | 8 |
| | `SUBADDRESSES`, `WATCH_PROXY`, `WATCH_THEMES`, `WATCH_SAMPLE` | `/etc/ccs-front/subaddresses.txt`; `socks5h://host.docker.internal:9050` (Tor, step 1; the host setup: `127.0.0.1`) and a clearnet proxy elsewhere; `1`; `10` (other pages checked each run, at random) | 8 |
| `/etc/ccs/trusted-signers` | the attesters you trust | their keys' fingerprints, one a line | upgrading |
| `/opt/ccs-bash/contrib/docker/backend/.env` | `CCS_BASH_IMAGE`, `CCS_FRONT_IMAGE`, `WALLET_IMAGE` | the attested IDs of [the releases](#the-releases); the wallet's, as built | docker, upgrading |
| | `CCS_UID`, `GIT_UID`, `FRONT_UID`, `WALLET_UID`, `PUSH_UID`, `SEND_UID`, `WATCH_UID` | the host's users, `uid:gid` | docker |
| | `WALLET_PORT` | `18082`, `wallet-rpc.conf`'s `rpc-bind-port` (its healthcheck: without it the compose waits forever) | docker |
| | `CCS_PUSH`, `CCS_BACKUP`, `CCS_SITE_URL` | `ccs-data@<web server>`, `ccs-backup@<backup machine>`, `https://ccs.getmonero.org` (also the feed's links: the same as the web server's `alert.conf` `SITE_URL`) | docker |
| | `CCS_PUSH_PORT`, `CCS_BACKUP_PORT` | `2223`, `2224` (the web server compose's gate and backup receiver) | docker |
| | `COMPOSE_FILE` | only with a monerod, Tor or bot on the backend's 127.0.0.1: `compose.yml:compose.host.yml` | docker |
| | `CCS_ONION` | optional: the site's onion address, for every page's footer; the same as the web server's `/etc/ccs-gate/onion` ([below](#the-onion-address)) | docker |
| the host setup: `/usr/local/bin/ccs-bash-run`, `ccs-front-run` | the image they run | its ID, `--pull never`, the attested one of [the releases](#the-releases) | 2, 5, upgrading |
| the host setup: `/usr/local/bin/ccs-bash-update` | `<web server>`, `<backup machine>` | their addresses | 9 |

**The web server**

| File | Setting | For ccs.getmonero.org | Step |
|---|---|---|---|
| `/etc/ssh/authorized_keys/ccs-data` | `from=`, the key | the backend's address and its push key, `command="/usr/local/bin/ccs-receive"`; `sshd_config`'s `Match User ccs-data` reads only it | 6 |
| `/etc/ccs-gate/` | `subaddresses.txt` and its `.pin`, `.asc`, `.key.asc` | the same files as the backend's | 6 |
| | `design.sha256` | the design release's files, from its zip (two-machines, "The gate") | 6 |
| the host setup's packages | the gate's tools | `apt install rsync curl qrencode git`, and `ccs-check` copied out of the attested gate image ([two machines, without Docker](two-machines.md#without-docker)) (in Docker: none, the gate's image has them) | 6 |
| | `design/<release>/` | the design's release zip, unpacked (the same as the backend's); `design.sha256` from it | 6 |
| | `markdown.awk` | `lib/markdown.awk` of the ccs-front-bash release the backend runs | 6 |
| | `proposals.conf` | `PROPOSALS_GIT=https://repo.getmonero.org/monero-project/ccs-proposals.git`, `PROPOSALS_BRANCH=master` (and `LINK_HOSTS`, other repositories a proposal's merge request link may be in, as host/path) | 6 |
| | `subaddresses.txt.viewkey` | the same as the backend's (the Verify page is then checked word for word) | 6 |
| | `allowed` | the General Fund, `888tNkZrPN6JsEgekjMnABU4TBzc2Dt29EPAvkRxbANsAnjyPbb3iQ1YBRk1UXcdRsiKc9dhwMVgN5S9cQUiyoogDavup3H`, and any address a proposal's text quotes (the gate's refusal names it) | 6 |
| | `alert.conf` | `ALERT_URL` (the bot), `SITE_URL=https://ccs.getmonero.org` (the gate takes a feed only with links under it) | 8 |
| | `onion` | optional: the site's onion address, one line (Tor's `/var/lib/tor/hidden_service/ccs/hostname`, [two machines](two-machines.md)); the only one the footer may show | 6 |
| nginx | `server_name`, the certificate | `ccs.getmonero.org`, from certbot | 6 |
| | `snippets/ccs-headers.conf` | the security headers, as in two-machines (A+ on securityheaders.com) | 6 |

### The onion address

Optional: with an onion service ([two machines](two-machines.md), "An onion service"), every
page's footer says "Also on Tor: <its address>". The address is in two places, which must agree:
the web server's `/etc/ccs-gate/onion` (root, 644: the only onion the gate lets a footer show) and
the backend compose's `.env`, `CCS_ONION` (what ccs-front-bash writes). Setting or changing it,
between runs: the web server's file first, then the backend's `.env` and `docker compose up -d
front` (a new variable needs a new container). Until the backend's next run, its pages still have
the old line: the gate holds them back (their last good copies stay live) and that run fails, which
is all. Removing it: the backend's `CCS_ONION` first, then the file.

### The feed

`/feed.xml`, RSS: each proposal put to Funding Required, and each fully funded (its goal raised in
confirmed donations while in Funding Required), the 50 newest. ccs-bash records when each happened
(`proposals.csv`'s `funding_required_date` and `funded_date`), ccs-front-bash writes the feed with
the backend's `CCS_SITE_URL`, and the gate takes it only exactly in that form, each item a link to
one of the site's proposal pages under its own `alert.conf` `SITE_URL`: set the two to the same
address. A proposal funded before ccs-bash recorded it has no "fully funded" item.

**The backup machine:** the `ccs-backup` account, with the backend's key in
`/etc/ssh/authorized_keys/ccs-backup` (step 7).

**The IRC bot.** Both machines send one line of text by HTTP POST to `ALERT_URL`: an IRC bot that
posts it to the channel (CptHook's `simple` module, `https://<host>/<endpoint>?channel=%23<channel>`;
or wmb, with `ALERT_TARGET` and `ALERT_PASSWORD`). Run it on its own machine, behind HTTPS: the
backend and the web server reach out to it, and nothing reaches the backend. Its port is
whatever it answers on, in the URL. In Docker the backend's watch container posts to it, so it
must be reachable from a container: a bot (or a Tor proxy) on the backend's own 127.0.0.1 needs
`compose.host.yml` ([docker](docker.md)); `ccs config:check` says so.

**Built into the design**, already right for ccs.getmonero.org: its address, the General Fund, the
proposals repository and its "Submit idea" link (ccs-front-hugo's `hugo.toml`). Changing any of
them is a new design release.

**The testnet** differs in places (its own wallet, proposals on Forgejo, machines that aren't
separate): [testnet](testnet.md). Don't copy it.

## Retiring a wallet

When the CCS moves to a new wallet (CCS2 to CCS3), the old one's donations keep counting: recorded
by proposal in `STATE_DIR/retired/<name>.csv` (no addresses; backed up, every version), and added
to the new wallet's each run. Funding-required proposals get new addresses. The switch takes
minutes, the site keeps its totals, and the old wallet needn't go quiet first: what reaches it
later (a deposit still too young, a saved address, a QR code shared before) is recorded after.

**Before** (days ahead, nothing changes yet):

- the new wallet, synced, and its **signed list**: made, signed, published and reproduced as in
  [step 4](#4-the-signed-subaddress-list), added as `subaddresses/<new wallet>/`;
- a **view-only copy of the old wallet**, synced, with a wallet-rpc of its own (another port, its
  own login): `retire-wallet --again` reads it afterwards, the live one being the new wallet;
- on the backup machine, as root, the old wallet's name and its follow-up records' in
  `/etc/ccs-backup/retired-names` (`ccs2`, `ccs2-2`, `ccs2-3`: it keeps no record of a name not
  listed there).

**The switch**, as root on the backend:

1. `systemctl stop ccs-bash`.
2. **Record it**, as ccs (the live wallet: the config's `RPC_URL`):
   ```
   runuser -u ccs -- /opt/ccs-bash/contrib/retire-wallet ccs2 /etc/ccs/ccs.conf
   ```
   It writes `retired/ccs2.csv` (every deposit with `MIN_CONFIRMATIONS`; it names those in the
   pool or younger, for later), clears those proposals' index and address in `proposals.csv`
   (the old file kept as `proposals.csv.before-retire-ccs2`: the old addresses, for later) and
   moves `deposits.csv` and `assigned.tsv` aside.
3. **The new wallet:** its files and `wallet-rpc.conf` (step 1; `systemctl restart
   ccs-wallet-rpc`), `WALLET_ADDRESS` (step 2), and its list on both machines in place of the old
   one's: `subaddresses.txt`, `.asc`, `.key.asc`, `.pin` and `.viewkey` (the Verify page's), in
   `/etc/ccs-front/` and `/etc/ccs-gate/`, checked as in step 4 (`list-signers` too, if the signer
   changes). Every address shown from then on is the new wallet's. On the backup machine, as
   root, move the old `deposits.csv` aside (it only takes one with every deposit it has).
4. **One run by hand**, then `systemctl start ccs-bash`: the same totals, new addresses.

**After:** a day later, and again now and then (until it says nothing new), with the loop paused,
the old wallet's view-only copy's wallet-rpc as `RPC_URL` (`RETIRE_RPC_USER`/`RETIRE_RPC_PASSWORD`
for its login):

```
systemctl stop ccs-bash
runuser -u ccs -- /opt/ccs-bash/contrib/retire-wallet --again ccs2 /etc/ccs/ccs.conf http://127.0.0.1:<its port>/json_rpc
/usr/local/bin/ccs-bash-update; systemctl start ccs-bash
```

Each time something came, it writes the next record (`retired/ccs2-2.csv`, then `-3`): only
deposits no record of `ccs2` has, under each proposal's name there; nothing new, nothing written. A
run counts a deposit once, whichever records have it. The name must be in `retired-names` first,
or the backup refuses it (a failed run until it is).

A proposal renamed later: rename it in `proposals.csv`, give its subaddress the new name as its
label (the run stops on a subaddress whose label names another proposal), and in every
`retired/*.csv` too, or it loses its retired donations ([edit the state](troubleshooting.md#edit-the-state)).

## Upgrading

A release is published by its repository (a tag: the release workflow builds it, checks it builds
the same twice and publishes the image or zip with its ID or sha256: [releasing](image.md#releases));
a deploy puts a set of three on the machines. Nothing changes on a machine until you deploy.

Images are built on the machine from the attested commit (the same commit gives the same ID, so it
can be checked); the design comes as its zip, checked by sha256. ccs-bash's image holds
`ccs-back.sh`, `lib/`, the compose's stage runner (`step`) and ccs-watch; the gate's image the gate
and `ccs-backup-receive` (ccs-front-bash's: its own). What runs on the machines from the checkout
(`ccs`, the compose files, the front's `step`, `container/build.sh`) isn't in an image, so another
commit with the same image files would build the same ID. They are trusted because they come from
the commit the signers attested: check that commit out, never only the tag.

### Deploying a set (the Docker setup)

The set is the three releases together, as [the releases](#the-releases) and ccs-sigs name it, e.g.
`ccs-bash-v0.2.34+ccs-front-bash-v0.1.21+ccs-front-hugo-v0.1.25`. Below, `SET` is that name, and
`IDB`, `IDG`, `IDF` and `ZIP` are what `verify` prints for it: ccs-bash's image ID, the gate's,
ccs-front-bash's, and the design zip's sha256. Only the parts that changed need doing (a new
design alone: the design lines of steps 3 to 5). Each machine: as root, a backup folder first
(`B=/root/ccs/pre-<SET>; install -d -m 700 "$B"`).

1. **Attested** (each machine checks it itself, the web server too, with its own ccs-sigs and
   `trusted-signers`: a taken-over backend would bring both the release and the sums it is
   compared with). First the fingerprints of the people you trust to attest this set, and only
   theirs, in `trusted-signers` (a key whose secret wasn't really destroyed could attest anything
   later, so an old throwaway key goes once its set is replaced):
   ```
   git clone -q https://github.com/plowsof/ccs-sigs /opt/ccs-sigs        # once; then, every time:
   git -C /opt/ccs-sigs pull -q --ff-only
   cd /opt/ccs-bash && env CCS_SIGS_REPO=/opt/ccs-sigs TRUSTED_KEYS=/etc/ccs/trusted-signers \
       contrib/release/verify "$SET"                                   # the web server: verify ccs-gate-vX too
   ```
   It prints each ID or sha256, how many signers agree (two by default) and the commits they
   name. Too few: wait, or attest it yourself ([contrib/release](../contrib/release/README.md)).
   `--min-signers 1` is for the testnet only: with one signer, the one person who wrote a release
   also vouches for it, for the backend and for the gate that checks it alike.
2. **Built from those commits and compared** (the loop keeps running). Not the tag: a tag can move,
   and the build runs as root. A clone of its own, so the running checkout stays as it is:
   ```
   W=/root/ccs/src-ccs-bash; rm -rf "$W"; git clone -q https://github.com/plowsof/ccs-bash "$W"
   git -C "$W" checkout -q <ccs-bash's commit>; git -C "$W" describe --tags     # the release
   (cd "$W" && container/build.sh ccs-bash:<release>)                         # the backend
   (cd "$W" && container/build.sh ccs-gate:<release> gate.Dockerfile)          # the web server's
   docker image inspect ccs-bash:<release> --format '{{.Id}}'                  # must be IDB
   ```
   The same for ccs-front-bash (`/opt/ccs-front-bash`, its commit, `container/build.sh
   ccs-front-bash:<release>`, must be IDF). Any other ID: stop. The gate's image is built on the
   web server, or here and loaded there (`docker save ccs-gate:<release> | ssh <web server>
   docker load`, its ID checked there). A build that stops with `sources has files that are not
   in sources.lock`: a source an older release needed is still in `container/sources/` (a
   download cache, not in git); move it aside.
3. **The web server first**, so its gate allows the new pages (`/opt/ccs-bash` here is the web
   server's own checkout, at ccs-bash's attested commit):
   ```
   D=/opt/ccs-bash/contrib/docker/web; cp -a "$D/.env" /etc/ccs-gate/design.sha256 "$B/"
   # a new design: fetched here, its sha256 the attested one, unpacked beside the old ones
   curl -fsSLo /tmp/d.zip https://github.com/plowsof/ccs-front-hugo/releases/download/<release>/ccs-front-hugo-<release>.zip
   echo "$ZIP  /tmp/d.zip" | sha256sum -c -
   unzip -q /tmp/d.zip -d /etc/ccs-gate/design/<release>
   (cd /etc/ccs-gate/design/<release> && find . -type f ! -name '*.html' -exec sha256sum {} +) > /tmp/lines
   flock /var/lib/ccs-gate/lock sh -c 'cat /tmp/lines >> /etc/ccs-gate/design.sha256'
   # a new gate
   git -C /opt/ccs-bash fetch -q --tags && git -C /opt/ccs-bash checkout -q <ccs-bash's commit>
   sed -i "s|^CCS_GATE_IMAGE=.*|CCS_GATE_IMAGE=$IDG|" "$D/.env"
   cd "$D" && docker compose config -q && docker compose --profile init run --rm -T init && docker compose up -d
   docker compose ps                                                           # healthy
   ```
   A changed `markdown.awk` beside the old as `/etc/ccs-gate/markdown-<release>.awk`. The old
   designs stay: the gate takes a page of any of them, so the backend can switch later. The
   backup machine: its compose the same way (`--profile backup up -d backup`).
4. **The backend, prepared** (the loop keeps running): a stopped container on each new image, so
   no cleanup removes it (`docker create --name ccs-bash-keep-<release> --network none "$IDB"`, the
   same for ccs-front-bash), and the design unpacked beside the one in use:
   ```
   curl -fsSLo /tmp/d.zip …; echo "$ZIP  /tmp/d.zip" | sha256sum -c -
   rm -rf /opt/ccs-front-hugo/public.new && unzip -q /tmp/d.zip -d /opt/ccs-front-hugo/public.new
   chmod -R u=rwX,go=rX /opt/ccs-front-hugo/public.new
   ```
5. **The backend, switched between runs:** wait until a run has pushed (`ccs status`: no run
   going; or `/var/lib/ccs/run/push/done` changes), then at once:
   ```
   D=/opt/ccs-bash/contrib/docker/backend; cp -a "$D/.env" /opt/ccs-front-hugo/VERSION "$B/"
   git -C /opt/ccs-bash rev-parse HEAD > "$B/commit"
   git -C /opt/ccs-bash fetch -q --tags && git -C /opt/ccs-bash checkout -q <ccs-bash's commit>
   sed -i -e "s|^CCS_BASH_IMAGE=.*|CCS_BASH_IMAGE=$IDB|" -e "s|^CCS_FRONT_IMAGE=.*|CCS_FRONT_IMAGE=$IDF|" "$D/.env"
   mv /opt/ccs-front-hugo/public /opt/ccs-front-hugo/public.<old release>
   mv /opt/ccs-front-hugo/public.new /opt/ccs-front-hugo/public
   echo "<release> $ZIP" > /opt/ccs-front-hugo/VERSION
   cd "$D" && docker compose config -q && docker compose up -d
   ```
   (`front` mounts `/opt/ccs-front-hugo`, so the renamed `public` is seen; nothing else to
   restart.) A design and a ccs-front-bash that need each other (a new `{{slot}}`) switch
   together, as here; the gate of step 3 must already know the slot.
6. **Watched:** the next run, every stage `ok` and the push `pushed` (`ccs status`), ccs-watch's
   check after it; `ccs config:check` with nothing failing (it says when an image isn't in an
   attestation). Then the set in [the releases](#the-releases), and the previous set's signers
   out of `trusted-signers` (on each machine) unless they attested this one too.
7. **Going back:** the backend's `.env` and checkout from `$B` (`git checkout $(cat $B/commit)`),
   the old `public` back in place, `docker compose up -d` between runs; the web server's `.env`
   from `$B`, then init and `up -d` (its `design.sha256` can keep the new lines). The old images
   are still there: their keep containers.

The host setup (no Docker): the same, but the new IDs go in `ccs-bash-run` and `ccs-front-run`
(by ID, `--pull never`), and the switch is made with `systemctl stop ccs-bash` between runs. Its
web server takes the new `contrib/ccs-receive` from the checkout and `ccs-check` copied out of the
new gate image ([two machines, without Docker](two-machines.md#without-docker)), both before the
backend switches. Root's
`ccs-bash-update` isn't in a release: compare it with [setup's](setup.md#the-update-script-the-host-setup)
at the new commit (after ccs-bash v0.2.34: the push's `--checksum`).

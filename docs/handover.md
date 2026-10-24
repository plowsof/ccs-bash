# Handover: running the CCS on ccs-bash

For the people who run ccs.getmonero.org today (ccs-back, PHP and MySQL, and the Jekyll
ccs-front): how to move it to ccs-bash and the static site made from it, in stages. Each stage
works on its own, can be stopped at, and says how to go back. Why it is built this way, and what
each machine may do: [the design](design.md).

**What stays the same:** the proposals repository (GitLab, or Forgejo later), the CCS wallet and
every proposal's subaddress, the site's addresses and `/projects`.

**What goes:** PHP, MySQL, Jekyll and Ruby. Nothing that serves the site runs code; the public
web server only serves files.

A working example of the end result: the testnet CCS, https://ccs.monerodevs.org, set up
exactly as below.

Where it ends up (stage 5), and what each part does:

<p align="center"><img src="design.svg" width="900" alt="The recommended architecture: the backend (wallet, ccs-bash, ccs-front-bash) makes the whole site from the design and pushes it to a web server whose gate checks every address against the signed list; ccs-watch checks the live pages and alerts IRC; releases are attested in ccs-sigs"></p>

## The parts

| Repository | What it is | Runs on |
|---|---|---|
| [ccs-bash](https://github.com/plowsof/ccs-bash) (this one) | the backend: proposals, the wallet, totals, addresses, as JSON | the backend |
| [ccs-front-bash](https://github.com/plowsof/ccs-front-bash) | the site builder: fills the design with ccs-bash's data, every page, in bash | the backend |
| [ccs-front-hugo](https://github.com/plowsof/ccs-front-hugo) | the design: the site's HTML and CSS, built once with Hugo, released as a reproducible zip | nowhere live (downloaded, sha256 checked) |
| [ccs-sigs](https://github.com/plowsof/ccs-sigs) | attestations: people who rebuilt a release and signed what they got | nowhere (checked before installing a release) |

### Current releases, tested together

The three are released separately; these versions work together and run the testnet CCS.
Install these tags. A row is added with each release.

| Set | ccs-bash | ccs-front-bash | ccs-front-hugo | Running on |
|---|---|---|---|---|
| 2026-10-24 | v0.2.7 | v0.1.10 | v0.1.9 | testnet ([ccs.monerodevs.org](https://ccs.monerodevs.org)) |

Before installing a release, check its attestations: `contrib/release/verify <release>` (as
Feather Wallet's releases are checked), then that the image ID or zip sha256 you are about to
run is the attested one ([contrib/release](../contrib/release/README.md)).

## Decide first

- **Machines.** The recommended end: a **backend** that accepts no connections (the wallet,
  ccs-bash, ccs-front-bash) and a **web server** that only receives the finished site and serves
  it. Stages 1 and 2 work on today's one machine; stage 3 splits it.
- **The wallet.** The CCS wallet, view-only. Its address and view key are public: luigi1111
  published them in
  [monero-project/meta #935](https://github.com/monero-project/meta/issues/935#issuecomment-1867257410).
- **Who makes and signs the subaddress list** (stage 4): a Core Team member.
- **Where alerts go** (stage 5): an IRC bot that takes a POST, ntfy, or similar; and a machine
  to keep backups of the state file.

## Stage 1: ccs-back → ccs-bash (Jekyll stays)

The JSON ccs-front reads comes from ccs-bash instead of ccs-back. Do [setup](setup.md) steps 1–7
(with the image, check its ID). What replaces what:

| ccs-back | ccs-bash |
|---|---|
| proposals in `ccs-back/storage/app/proposals` | `/var/lib/ccs/proposals` ([setup](setup.md) step 2) |
| `ccs-front/_data/*.json` symlinked to single files | `_data` is the directory `/var/lib/ccs/out` (step 4) |
| `.env`: `RPC_URL`, `RPC_USER`, `RPC_PASSWORD`, `REPOSITORY_URL` | the same in `/etc/ccs/ccs.conf`, plus `WALLET_ADDRESS` |
| cron: `git pull; php artisan schedule:run; jekyll build` | `ccs-bash-update` (step 6 or 7) |
| nginx: `/index.php` fallback, `location ~ \.php$` | gone; `/projects` is a static file (step 5) |
| wallet-rpc, however it ran | its own user and service (step 1) |

1. **Back up** the database (`mysqldump`), the cron line and the old JSON.

2. **Export the state** so every proposal keeps its subaddress, and keep the same wallet.
   `<ccs_db>` is the database (add `-u`/`-p`, or `docker exec <db> mysql ...`); `ORDER BY id`
   keeps the old `/projects` order.

   Upstream ccs-back (no funding-required date; proposals funded after the switch get one):

   ```
   mysql -B -N -e "SELECT filename, IFNULL(gitlab_url, ''), IFNULL(subaddr_index, ''), IFNULL(address, ''), '' FROM projects ORDER BY id" <ccs_db> | jq -rR 'split("\t") | @csv' > /var/lib/ccs/state/proposals.csv
   chown ccs:ccs /var/lib/ccs/state/proposals.csv
   ```

   With the `funding_required_date` column (plowsof's fork; stored as UTC):

   ```
   mysql -B -N -e "SELECT filename, IFNULL(gitlab_url, ''), IFNULL(subaddr_index, ''), IFNULL(address, ''), IFNULL(DATE_FORMAT(funding_required_date, '%Y-%m-%dT%H:%i:%sZ'), '') FROM projects ORDER BY id" <ccs_db> | jq -rR 'split("\t") | @csv' > /var/lib/ccs/state/proposals.csv
   chown ccs:ccs /var/lib/ccs/state/proposals.csv
   ```

   No jq on the host (with the image)? Use the image's:
   `docker run --rm -i --network none --entrypoint jq ccs-bash -rR 'split("\t") | @csv'`.

   Amounts aren't exported; they come from the wallet's history, so the wallet needs all of
   it (the same wallet, or restored from before the first donation).

   **The wallet** moves to step 1's service: stop the old wallet-rpc (it saves on exit), copy
   `<name>` and `<name>.keys` into `/var/lib/ccs/wallet` (owner `ccs-wallet`, mode 600), set
   `wallet-file`, start it. `wallet_info` in `monero-wallet-cli` must say `Watch only`; if it
   can spend, use a view-only one instead (`--generate-from-view-key`, with the main address,
   secret view key and a restore height from before the first donation).

3. **Run ccs-bash once next to ccs-back** (`ccs-bash-run`) and compare (below). Stop ccs-back's
   cron first if any funding-required proposal has no address yet, or both would assign one.

   `donations at subaddress ..., which proposals.csv doesn't have` means the wallet has
   donations at indices the export lacks. On the real CCS, the export is incomplete: find out
   why. Old indices that belong to nothing (say from before a database reset) can be recorded
   as retired, never shown or handed out (here 8 and 9):

   ```
   curl -s --digest -u 'ccs:<rpc password>' http://127.0.0.1:18082/json_rpc \
       -d '{"jsonrpc":"2.0","id":0,"method":"get_address","params":{"account_index":0,"address_index":[8,9]}}' \
     | jq -r '.result.addresses[] | ["retired-subaddress-\(.address_index)", "", .address_index, .address, ""] | @csv' \
     >> /var/lib/ccs/state/proposals.csv
   ```

4. **Switch over:** replace the cron line (step 6), drop ccs-back's `--tx-notify` script (step 7
   replaces it without root), point ccs-front at the new output (steps 4–5), and stop ccs-back
   and its database (php-fpm, mysql).

**Going back:** keep ccs-back and its database for a while; going back is restoring the cron line
and starting them.

**Comparing:** the JSON should match except `donate-qr-code` (another encoder) and the
differences below:

```
norm() { jq -S '[.[] | {stage, proposals: [.proposals[] | del(.["donate-qr-code"])] | sort_by(.name)}]' "$1"; }
diff <(norm ccs-back/storage/app/proposals.json) <(norm /var/lib/ccs/out/proposals.json)
```

**Differences from ccs-back:**

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

## Stage 2: Jekyll → ccs-front-bash and the design

The site is made by ccs-front-bash from ccs-front-hugo's design, on the same machine, instead
of Jekyll: no Ruby, no JavaScript on the site. ccs-front-bash's
[docs/setup.md](https://github.com/plowsof/ccs-front-bash/blob/master/docs/setup.md), steps 1–4:
the design's release zip (sha256 checked), ccs-front-bash and `ccs-front-run`, and nginx with its
root on the site. Then [the update](#the-update) with ccs-front-bash in it; on one machine, without
the push and the page check.

**Going back:** point nginx back at the Jekyll site and restore the stage 1 update.

## Stage 3: a separate web server

The backend stops taking connections: after each run it pushes the finished site to a web server
that can only receive it and serve it, and that checks every address in it. [Two
machines](two-machines.md), way A (the push account, nginx, HTTPS), and "The gate". The push is
part of [the update](#the-update).

**Going back:** point the DNS back at the backend's nginx.

## Stage 4: the signed subaddress list

Every donation address shown must be one of the wallet's: a list of its first 15,000
subaddresses, made once and signed, checked by the backend each run, by the web server's gate on
each push, and on the site's Verify page by anyone. A **Core Team member** makes and signs it;
contributors can make it from the same public address and view key and confirm its sha256.
ccs-front-bash's [docs/setup.md](https://github.com/plowsof/ccs-front-bash/blob/master/docs/setup.md),
step 5. For the CCS wallet, its view key file (shown on the Verify page, with the commands to ask
a copy of the wallet about an address):

```
62ad19781466882d8df0ae85743abcc5c8ef81e52e051e7cc56fe3c610d18001
source https://github.com/monero-project/meta/issues/935#issuecomment-1867257410
source-text shared by luigi1111 here
```

The list goes to both machines by hand, never pushed by the backend, so a taken-over backend
can't swap it. A new list (more subaddresses, a new wallet) is made, signed and installed the
same way.

**Going back:** run ccs-front-bash without the list (no fifth argument); the gate needs it, so
only with one machine, or with the gate's push key back on plain rrsync.

## Stage 5: alerts and backup

- **The backend watches the web server:** after each push, `ccs-watch` fetches the donation pages
  as a visitor (through Tor) and compares them with what was pushed; a page that differs, or a
  backend that stops running, is an alert to IRC. [Two
  machines](two-machines.md#watching-the-web-server-way-a-the-backend-raises-the-alarm).
- **The web server tells IRC itself** when its gate holds a page back ("The gate").
- **The state is backed up:** `proposals.csv`, the one file that can't be made again, goes to
  another machine on each change, to an account that can only add copies. [Setup](setup.md#backing-up-the-state).

## The update

One run of everything, every 2 minutes and on each new donation ([setup](setup.md) steps 6–7), as
root (it only starts each step as that step's own user). This is the only full copy of it.

```
#!/bin/sh
# /usr/local/bin/ccs-bash-update (chmod 755)
L=/var/log/ccs-bash.log W=/opt/ccs-bash/contrib/ccs-watch failed=''

# the proposals; GitLab or Forgejo down: give up, not a failed run (the last checkout stays)
timeout -k 5 40 runuser -u ccs-git -- env HOME=/ git -C /var/lib/ccs/proposals pull -q --ff-only

# ccs-bash: totals, addresses, the JSON
ccs-bash-run >> $L 2>&1 || failed="ccs-bash"

# the state, to the backup machine when it changed (it keeps every version)
sum=$(sha256sum /var/lib/ccs/state/proposals.csv | cut -c1-64)
if [ "$sum" != "$(cat /var/lib/ccs/backup-sent 2>/dev/null)" ] \
    && timeout -k 5 30 ssh -T -i /root/.ssh/ccs-backup_ed25519 -o BatchMode=yes -o IdentitiesOnly=yes \
        -o ConnectTimeout=15 ccs-backup@<backup machine> < /var/lib/ccs/state/proposals.csv >> $L 2>&1; then
    echo "$sum" > /var/lib/ccs/backup-sent
fi

# ccs-front-bash makes the site; it goes to the web server, which must then serve exactly that
if ccs-front-run >> $L 2>&1; then
    if timeout -k 5 120 runuser -u ccs -- rsync -a --delay-updates \
            -e "ssh -p 22 -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=15" \
            /var/lib/ccs/www/site/ ccs-data@<web server>: >> $L 2>&1; then
        runuser -u ccs -- $W https://<the site> /var/lib/ccs/www/site >> $L 2>&1
    else failed="${failed:+$failed, }the push"; fi
else failed="${failed:+$failed, }ccs-front-bash"; fi

# how the run went: three failed runs in a row alert, so a stopped backend can't go unnoticed
runuser -u ccs -- $W --run "${failed:-ok}" >> $L 2>&1
```

| Part | Stage | Without it |
|---|---|---|
| the pull, `ccs-bash-run` | 1 | |
| the backup | 5 | drop the block; back up `proposals.csv` some other way |
| `ccs-front-run` | 2 | (stage 1: Jekyll instead, [setup](setup.md) step 6) |
| the push, `ccs-watch` | 3, 5 | one machine: drop both; nginx serves `/var/lib/ccs/www/site` |
| `ccs-watch --run` | 5 | without `/etc/ccs/alert.conf` it only logs |

`-p 22` is the web server's ssh port, given in full in case this machine's `ssh_config` defaults
to another.

## Upgrading

A new release: check its attestations (above), build it from its tag, or pull it by the digest in
its release notes, and compare the image ID; for the design, download the zip and check its
sha256. Then install it ([the pinned image](image.md)), and add a row to the table above when it
runs. If anything else on the backend prunes Docker images, keep a stopped container on each
image ([troubleshooting](troubleshooting.md)).

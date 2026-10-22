# ccs-bash

A small replacement for [ccs-back](https://repo.getmonero.org/monero-project/ccs-back),
the backend of the Monero Community Crowdfunding System.
It is a bash script run from cron. It has no web server, database or PHP;
it uses a view-only `monero-wallet-rpc` and a few Debian packages.

It writes the files [ccs-front](https://repo.getmonero.org/monero-project/ccs-front) (Jekyll)
reads, `proposals.json` and `completed-proposals.json`, plus `projects.json` for a `/projects` API.

## What a run does

`ccs-back.sh` runs these steps from top to bottom:

1. **Read proposals.** Parse the frontmatter of every `.md` file in the proposals checkout
   (`lib/frontmatter.awk`). Files that don't match the expected format are logged and skipped.
2. **Record new proposals.** For a file seen for the first time, find the merged GitLab MR that
   added it and remember its URL. If it is funding-required, also remember when funding started.
3. **Check the wallet.** Make sure the wallet knows every subaddress in the state file and
   that they match. A restored wallet gets its subaddresses re-created; a wrong wallet stops the run.
4. **Assign addresses.** Each funding-required (`fr`) proposal without an address gets a new
   subaddress (labelled with the filename).
5. **Count donations.** Per subaddress, txes with at least `MIN_CONFIRMATIONS` are
   `amount-funded`; newer ones, pool included, are `amount-pending`.
6. **Fetch ideas.** Open MRs that add a single new proposal file. If GitLab is down,
   the previous list is kept.
7. **Write the JSON files.** `lib/site.jq` builds the files, which are swapped in atomically.

| File | Does |
|---|---|
| `ccs-back.sh` | entry point, the steps above |
| `lib/common.sh` | logging, config, atomic writes, filename check |
| `lib/frontmatter.awk` | the proposal format parser (and its spec, in the comment at the top) |
| `lib/proposals.sh` | proposals to JSON, the state file |
| `lib/gitlab.sh` | ideas and merged MR lookup |
| `lib/wallet.sh` | wallet RPC, subaddresses, donation totals, QR codes |
| `lib/site.jq` | output format for ccs-front and `/projects` |

## State

Everything is recomputed on each run, except `STATE_DIR/proposals.tsv`:

```
filename <TAB> gitlab_url <TAB> subaddr_index <TAB> address <TAB> funding_required_date
```

This file says which subaddress belongs to which proposal, so **back it up**.
The wallet can always be restored from its keys; this file cannot be recreated.
`STATE_DIR/qr/` only caches QR code images and can be deleted.

## Dependencies

```
apt install bash coreutils curl jq git qrencode util-linux
```

`awk` can be mawk or gawk. No other runtime is needed. The tests need nothing extra.
`qrencode` is often not installed by default (it wasn't on Ubuntu 22.04).

## Setup

1. Run a view-only wallet with monero-wallet-rpc, bound to localhost, with a login:

   ```
   monero-wallet-rpc --daemon-address 127.0.0.1:18081 --wallet-file /var/lib/ccs/wallet/ccs \
       --rpc-bind-ip 127.0.0.1 --rpc-bind-port 18082 --rpc-login ccs:<password> \
       --tx-notify /usr/local/bin/ccs-notify
   ```

   It only holds the view key, so it cannot spend. If it leaks, the cost is donation privacy.
   With `--disable-rpc-login`, leave `RPC_USER` empty.
   `--tx-notify` is optional: it runs a script on each incoming tx (see step 5).

2. Create a user and the directories. The user must be able to read the proposals checkout,
   so keep it outside `/root`:

   ```
   useradd --system --home-dir /var/lib/ccs --shell /usr/sbin/nologin ccs
   install -d -m 755 /var/lib/ccs
   install -d -o ccs -g ccs -m 755 /var/lib/ccs/state /var/lib/ccs/out
   git clone https://repo.getmonero.org/monero-project/ccs-proposals.git /var/lib/ccs/proposals
   install -d -g ccs -m 750 /etc/ccs
   install -g ccs -m 640 ccs.conf.example /etc/ccs/ccs.conf    # then edit it
   ```

3. Point ccs-front at the output. `OUTPUT_DIR` is laid out like ccs-front's `_data` directory,
   so link or mount the **directories**:

   ```
   rm -rf ccs-front/_data ccs-front/proposals
   ln -s /var/lib/ccs/out       ccs-front/_data
   ln -s /var/lib/ccs/proposals ccs-front/proposals
   ```

   With Docker, mount the directories as well:

   ```
   - /var/lib/ccs/out:/workspace/ccs-front/_data:ro
   - /var/lib/ccs/proposals:/workspace/ccs-front/proposals:ro
   ```

   Don't bind mount the single JSON files. ccs-bash replaces them with `mv`, and a
   single-file bind mount keeps showing the old file forever.

4. Optional `/projects` API, nginx:

   ```
   location = /projects {
       alias /var/lib/ccs/out/projects.json;
       add_header Content-Type application/json;
   }
   ```

5. Run it from root's cron, dropping to the `ccs` user for ccs-bash itself:

   ```
   */2 * * * * git -C /var/lib/ccs/proposals pull -q --ff-only ; runuser -u ccs -- /opt/ccs-bash/ccs-back.sh /etc/ccs/ccs.conf >> /var/log/ccs-bash.log 2>&1 ; cd /opt/ccs-front && jekyll build -q
   ```

   Overlapping runs are skipped (`flock`). Files that fail to parse are logged on every run,
   so rotate the log, for example with `/etc/logrotate.d/ccs-bash`:

   ```
   /var/log/ccs-bash.log {
       weekly
       rotate 4
       compress
       missingok
       notifempty
   }
   ```

   For `--tx-notify`, write a script (e.g. `/usr/local/bin/ccs-notify`) with the same two
   commands as the cron line: the `runuser ... ccs-back.sh` and the `jekyll build`.

The first run on a fresh install looks up the merged MR of every proposal, which
takes a few minutes. After that, only new proposals are looked up.

## Moving from ccs-back

1. **Back up** the database (`mysqldump`), the cron line, and the old JSON files.

2. **Export the state**, so every proposal keeps its subaddress, and use the same wallet.
   Replace `<ccs_db>` with the database name (and add `-u`/`-p` as needed).
   `ORDER BY id` keeps `projects.json` in the old order. With Docker, run it through
   `docker exec <db container> mysql ...`.

   Upstream ccs-back (as running for getmonero.org):

   ```
   mysql -B -N -e "SELECT filename, IFNULL(gitlab_url, ''), IFNULL(subaddr_index, ''), IFNULL(address, ''), '' FROM projects ORDER BY id" <ccs_db> > /var/lib/ccs/state/proposals.tsv
   chown ccs:ccs /var/lib/ccs/state/proposals.tsv
   ```

   Upstream has no funding-required date, so existing proposals get none; proposals
   that become funding-required after the switch get one.

   ccs-back with the `funding_required_date` column (plowsof's fork):

   ```
   mysql -B -N -e "SELECT filename, IFNULL(gitlab_url, ''), IFNULL(subaddr_index, ''), IFNULL(address, ''), IFNULL(DATE_FORMAT(funding_required_date, '%Y-%m-%dT%H:%i:%sZ'), '') FROM projects ORDER BY id" <ccs_db> > /var/lib/ccs/state/proposals.tsv
   chown ccs:ccs /var/lib/ccs/state/proposals.tsv
   ```

   The date is exported as UTC, which is what ccs-back stores (Laravel's default timezone).

   Raised amounts and deposits are not exported: ccs-bash recomputes them from the
   wallet's history, so the wallet must have the full history (the same wallet, or one
   restored from a height before the first donation).

3. **Run ccs-bash next to ccs-back once** and compare the output (see below). While both
   run, a funding-required proposal without an address would get a subaddress from each of
   them, so check there is none first, or stop ccs-back's cron before the first run.

4. **Switch over:** replace ccs-back's cron line and `--tx-notify` script with ccs-bash's,
   point ccs-front at the new output directories (setup steps 3 and 4), then stop the
   ccs-back and database containers or services. Keep them until you are happy, so going
   back is just restoring the cron line and starting them again.

Comparing the output: the JSON should match except for `donate-qr-code` (a different QR
encoder) and the differences listed below. For example:

```
norm() { jq -S '[.[] | {stage, proposals: [.proposals[] | del(.["donate-qr-code"])] | sort_by(.name)}]' "$1"; }
diff <(norm ccs-back/storage/app/proposals.json) <(norm /var/lib/ccs/out/proposals.json)
```

Differences from ccs-back:

- **Totals:** donation totals are recomputed from the wallet on every run instead of being
  added up in a database, so a dropped or reorged tx no longer stays counted.
- **Locked txes:** a tx counts as funded at `MIN_CONFIRMATIONS`, not when its outputs unlock;
  before that it is pending. Time-locked txes (`unlock_time` set) are not counted.
- **Amounts:** `1,500` means 1500 (ccs-back read it as 1.5). All amounts are shown with
  4 decimals (`"85.0000"`), as strings. Raised and pending are cut off at 4 decimals, not
  rounded, and the percentage is rounded down: 99.99996 of 100 XMR shows as `99.9999` and
  99%, where ccs-back showed `100.0000` and 100%. Sums are exact (integer atomic units).
- **Authors:** `0xfffc` stays `0xfffc` (ccs-back's YAML parser turned it into the number 65532).
- **Dates:** only written-out months are understood (`June 25th, 2021`, `10 August 2021`),
  and they keep their year (ccs-back read `10 August, 2021` as 20:21 this year).
  Numeric dates like `02/14/2017` show no date.
- **`/projects`:** lists proposals that still have a file in the repo. ccs-back also listed
  database rows whose file had been deleted.
- **GitLab:** MR lists are paginated, so MRs past the first 50 are seen.
- **Removed:** the `/projects/<index>` web pages, GitHub and Zcoin support.

## Tests

```
tests/run.sh             # end-to-end run on tests/fixtures with a fake wallet and GitLab
UPDATE=1 tests/run.sh    # rewrite tests/expected after an intended change, then check the diff
shellcheck -x ccs-back.sh lib/*.sh tests/*.sh
```

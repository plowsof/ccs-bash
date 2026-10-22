# Moving from ccs-back

Do [setup](setup.md) steps 1 to 3 first (A or B; with B, check the image ID before the first run).
Where upstream ccs-back's readme put things, and what replaces them:

| ccs-back | ccs-bash |
|---|---|
| proposals checkout in `/var/www/html/ccs-back/storage/app/proposals` | its own checkout in `/var/lib/ccs/proposals` ([setup](setup.md) step 2) |
| `ccs-front/_data/*.json` symlinked to single files in `ccs-back/storage/app` | the whole `_data` directory is `/var/lib/ccs/out` ([setup](setup.md) step 4) |
| `.env`: `RPC_URL`, `RPC_USER`, `RPC_PASSWORD`, `REPOSITORY_URL` | the same names in `/etc/ccs/ccs.conf`, plus `WALLET_ADDRESS` |
| cron: `git pull; php artisan schedule:run; jekyll build`, every minute | `ccs-bash-update` ([setup](setup.md) step 6, or step 7) |
| nginx: `/index.php` fallback and the `location ~ \.php$` block | removed; `/projects` is the static file ([setup](setup.md) step 5) |
| wallet-rpc, however it was started | its own user and service ([setup](setup.md) step 1), see step 2 below |

Then:

1. **Back up** the database (`mysqldump`), the cron line, and the old JSON files.

2. **Export the state**, so every proposal keeps its subaddress, and use the same wallet
   (its main address goes in `WALLET_ADDRESS`).
   Replace `<ccs_db>` with the database name (and add `-u`/`-p` as needed).
   `ORDER BY id` keeps `projects.json` in the old order. With Docker, run it through
   `docker exec <db container> mysql ...`.

   Upstream ccs-back (as running for getmonero.org):

   ```
   mysql -B -N -e "SELECT filename, IFNULL(gitlab_url, ''), IFNULL(subaddr_index, ''), IFNULL(address, ''), '' FROM projects ORDER BY id" <ccs_db> | jq -rR 'split("\t") | @csv' > /var/lib/ccs/state/proposals.csv
   chown ccs:ccs /var/lib/ccs/state/proposals.csv
   ```

   Upstream has no funding-required date, so existing proposals get none; proposals
   that become funding-required after the switch get one.

   ccs-back with the `funding_required_date` column (plowsof's fork):

   ```
   mysql -B -N -e "SELECT filename, IFNULL(gitlab_url, ''), IFNULL(subaddr_index, ''), IFNULL(address, ''), IFNULL(DATE_FORMAT(funding_required_date, '%Y-%m-%dT%H:%i:%sZ'), '') FROM projects ORDER BY id" <ccs_db> | jq -rR 'split("\t") | @csv' > /var/lib/ccs/state/proposals.csv
   chown ccs:ccs /var/lib/ccs/state/proposals.csv
   ```

   The date is exported as UTC, which is what ccs-back stores (Laravel's default timezone).

   With the container (B), the host may not have jq; use the image's, with no network: in
   either query, replace `jq -rR 'split("\t") | @csv'` with
   `docker run --rm -i --network none --entrypoint jq ccs-bash -rR 'split("\t") | @csv'`.

   Raised amounts and deposits are not exported: ccs-bash recomputes them from the
   wallet's history, so the wallet must have the full history (the same wallet, or one
   restored from a height before the first donation).

   Moving the wallet to [setup](setup.md) step 1's service: stop the old wallet-rpc (it saves the wallet
   on exit), copy the wallet's two files (`<name>` and `<name>.keys`) into `/var/lib/ccs/wallet`
   owned by `ccs-wallet` (mode 600), point `wallet-file` at them and start the service. Check
   it is view-only: `monero-wallet-cli --wallet-file <name>`, then `wallet_info` must say
   `Watch only`. If it can spend, make a view-only one from the main address and the secret view key
   (`monero-wallet-cli --generate-from-view-key <name>`, restore height from before the first
   donation) and use that instead.

3. **Run ccs-bash next to ccs-back once** (`ccs-bash-run`) and compare the output (see below). While both
   run, a funding-required proposal without an address would get a subaddress from each of
   them, so check there is none first, or stop ccs-back's cron before the first run.

   If the run stops with `donations at subaddress ..., which proposals.csv doesn't have`,
   the wallet holds donations at subaddresses no proposal in the export has, for example from
   before the database was reset. Find out where they came from first: on a real CCS this
   means the export is incomplete. Old ones that belong to nothing can be recorded as
   retired, so they are known but never handed out or shown, with the wallet's own address
   for each index (here 8 and 9):

   ```
   curl -s --digest -u 'ccs:<rpc password>' http://127.0.0.1:18082/json_rpc \
       -d '{"jsonrpc":"2.0","id":0,"method":"get_address","params":{"account_index":0,"address_index":[8,9]}}' \
     | jq -r '.result.addresses[] | ["retired-subaddress-\(.address_index)", "", .address_index, .address, ""] | @csv' \
     >> /var/lib/ccs/state/proposals.csv
   ```

4. **Switch over:** replace ccs-back's cron line with ccs-bash's ([setup](setup.md) step 6), drop
   ccs-back's `--tx-notify` script (it needs wallet-rpc to run as root; [setup](setup.md) step 7 does the
   same without), point ccs-front at the new output directories ([setup](setup.md) steps 4 and 5), then
   stop the ccs-back and database containers or services (with upstream's readme: php-fpm
   and mysql). Keep them until you are happy, so going
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
  `2021-06-25` works too. Numeric dates like `02/14/2017` show no date.
- **Frontmatter:** read as YAML (so Jekyll) reads it: `title: Talks #2` is `Talks` (the rest
  is a comment), `'single'` quotes work. What could be read two ways (a value over several
  lines, `>` or `|` blocks, `\` escapes, anchors, a line that isn't `key: value`, a key given
  twice) skips the file with the reason in the log. None of the current proposals do this.
- **`/projects`:** lists proposals that still have a file in the repo. ccs-back also listed
  database rows whose file had been deleted.
- **GitLab:** MR lists are paginated, so MRs past the first 50 are seen.
- **Removed:** the `/projects/<index>` web pages, GitHub and Zcoin support.

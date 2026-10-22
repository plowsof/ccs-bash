# Moving from ccs-back

First do [setup](setup.md) steps 1–3 (with B, check the image ID). What replaces what:

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

   No jq on the host (B)? Use the image's:
   `docker run --rm -i --network none --entrypoint jq ccs-bash -rR 'split("\t") | @csv'`.
   An older ccs-bash's `proposals.tsv`: `jq -rR 'split("\t") | @csv' proposals.tsv > proposals.csv`.

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
   donations at indices the export lacks. On a real CCS, the export is incomplete: find out
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
   and its database (php-fpm, mysql). Keep them for a while: going back is restoring the cron
   line and starting them.

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

# ccs-bash

A small replacement for [ccs-back](https://repo.getmonero.org/monero-project/ccs-back),
the backend of the Monero Community Crowdfunding System.
It is a bash script run from cron. It has no web server, database or PHP;
it uses a view-only `monero-wallet-rpc` and a few Debian packages.

It writes the same `proposals.json` and `complete.json` that
[ccs-front](https://repo.getmonero.org/monero-project/ccs-front) (Jekyll) reads.

## What a run does

`ccs-back.sh` runs these steps from top to bottom:

1. **Read proposals.** Parse the frontmatter of every `.md` file in the proposals checkout
   (`lib/frontmatter.awk`). Files that don't match the expected format are logged and skipped.
2. **Record new proposals.** For a file seen for the first time, find the merged GitLab MR that
   added it and remember its URL.
3. **Check the wallet.** Make sure the wallet knows every subaddress in the state file and
   that they match. A restored wallet gets its subaddresses re-created; a wrong wallet stops the run.
4. **Assign addresses.** Each funding-required (`fr`) proposal without an address gets a new
   subaddress (labelled with the filename).
5. **Count donations.** Sum the incoming transfers per subaddress that have at least
   `MIN_CONFIRMATIONS`.
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
| `lib/site.jq` | output format for ccs-front |

## State

Everything is recomputed on each run, except `STATE_DIR/proposals.tsv`:

```
filename <TAB> gitlab_url <TAB> subaddr_index <TAB> address
```

This file says which subaddress belongs to which proposal, so **back it up**.
The wallet can always be restored from its keys; this file cannot be recreated.
`STATE_DIR/qr/` only caches QR code images and can be deleted.

## Dependencies

```
apt install bash coreutils curl jq git qrencode util-linux
```

`awk` can be mawk or gawk. No other runtime is needed. The tests need nothing extra.

## Setup

1. Run a view-only wallet with monero-wallet-rpc, bound to localhost, with a login:

   ```
   monero-wallet-rpc --daemon-address 127.0.0.1:18081 --wallet-file /var/lib/ccs/wallet/ccs \
       --rpc-bind-ip 127.0.0.1 --rpc-bind-port 18082 --rpc-login ccs:<password>
   ```

   It only holds the view key, so it cannot spend. If it leaks, the cost is donation privacy.

2. Check out the proposals repo, copy `ccs.conf.example` to `/etc/ccs/ccs.conf` and edit it.

3. Point ccs-front at the output:

   ```
   ln -fs /var/lib/ccs/out/proposals.json ccs-front/_data/proposals.json
   ln -fs /var/lib/ccs/out/complete.json  ccs-front/_data/completed-proposals.json
   ln -fs /var/lib/ccs/proposals          ccs-front/proposals
   ```

4. Run it from cron as an unprivileged user that can write only `STATE_DIR` and `OUTPUT_DIR`:

   ```
   */2 * * * * git -C /var/lib/ccs/proposals pull -q --ff-only && /opt/ccs-bash/ccs-back.sh && cd /opt/ccs-front && jekyll build -q
   ```

   Overlapping runs are skipped (`flock`).

The first run on a fresh install looks up the merged MR of every proposal, which
takes a few minutes. After that, only new proposals are looked up.

## Moving from ccs-back

Export the existing addresses so every proposal keeps its subaddress, then use the same wallet:

```
mysql -B -N -e "SELECT filename, IFNULL(gitlab_url, ''), IFNULL(subaddr_index, ''), IFNULL(address, '')
                FROM projects" <ccs_db> > /var/lib/ccs/state/proposals.tsv
```

Differences from ccs-back:

- **Totals:** donation totals are recomputed from the wallet on every run instead of being
  added up in a database, so a dropped or reorged tx no longer stays counted.
- **Locked txes:** a tx is counted at `MIN_CONFIRMATIONS` (`0` includes the pool),
  not when its outputs unlock. Time-locked txes (`unlock_time` set) are not counted.
- **Amounts:** `1,500` means 1500 (ccs-back read it as 1.5). `amount-funded` is rounded to 4 decimals.
- **Dates:** only written-out months are understood (`June 25th, 2021`, `10 August 2021`).
  Anything else shows no date.
- **GitLab:** MR lists are paginated, so MRs past the first 50 are seen.
- **Removed:** the `/projects` web pages and API, GitHub and Zcoin support.

## Tests

```
tests/run.sh             # end-to-end run on tests/fixtures with a fake wallet and GitLab
UPDATE=1 tests/run.sh    # rewrite tests/expected after an intended change, then check the diff
shellcheck -x ccs-back.sh lib/*.sh tests/*.sh
```

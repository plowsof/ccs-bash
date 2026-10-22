<p align="center">
  <img src="logo.svg" width="180" alt="An orange clam seen from the side, eyes peeking out of its open shell, inside a gear">
</p>

# ccs-bash

**A blazingly fast, memory-safe CCS backend. Written in shell.**

- **Blazingly fast:** a full run takes about 3 seconds, once every 2 minutes.
- **Memory safe:** it has no memory. Everything is recomputed on each run, except one CSV file.
- **Fearless concurrency:** `flock -n`.
- **Zero-cost abstractions:** there are no abstractions.
- **A strong type system:** everything is a string, the money too. That's how the amounts stay exact.
- **A friendly compiler:** `shellcheck`.
- **Cargo:** `apt install jq`.

Not a crustacean. A mollusc.

A small replacement for [ccs-back](https://repo.getmonero.org/monero-project/ccs-back),
the backend of the Monero Community Crowdfunding System.
It is a bash script run from cron. It has no web server, database or PHP;
it uses a view-only `monero-wallet-rpc` and either a few Debian packages or a pinned
container image (see [Two ways to run it](#two-ways-to-run-it)).

It writes the files [ccs-front](https://repo.getmonero.org/monero-project/ccs-front) (Jekyll)
reads, `proposals.json` and `completed-proposals.json`, plus `projects.json` for a `/projects` API.

## Security

What an attacker wants is the donation addresses on the website: with a shell on a machine
that writes the JSON or serves the site, they can swap in their own address and collect the
donations. (The wallet is view-only, so the coins already received are not at risk; that
part was never the problem.) ccs-bash is about leaving as few ways in as possible:

- **Nothing to connect to.** ccs-bash is a cron job, not a service: no web server, no open
  port, no database. It only makes outgoing calls, to the wallet and to GitLab.
- **Few, well-kept dependencies.** About ten Debian packages, patched by Debian's security
  team, or the same tools from StageX, built from source (see [Dependencies](#dependencies)),
  instead of a framework and its package tree. All of ccs-bash is about 700 lines (500
  without comments) you can read in an afternoon.
- **Least privilege.** It runs as a `ccs` user that can only write its state and output
  folders. It refuses to run if it can write its own config (so not as root either).
- **Checks the wallet.** The wallet's main address is pinned in the config (`WALLET_ADDRESS`),
  which only root can change; every subaddress must also match the state file. A swapped
  wallet stops the run instead of getting its addresses published, even if the state file
  (which the `ccs` user can write) was changed to match it.
- **QR codes made fresh.** Every run makes the QR codes again from the addresses and
  never keeps them, so there is no stored image to swap for one with another address
  (which would send donors' money elsewhere while the address shown as text still looks
  right). CI reads qrencode's output back with a real decoder.
- **Untrusted text stays text.** Proposal titles and MR names are HTML-escaped and only
  ever handled as data (no `eval`, every JSON value built by jq), filenames are checked.
- **Can run apart from the website.** ccs-bash and ccs-front can be on
  [separate machines](#ccs-front-on-another-machine). Then the wallet machine accepts no
  connections at all: it pushes the JSON to the web server, whose key can only write into
  one folder (`rrsync -wo`). Nothing on the web server can reach the wallet machine, the
  state file (which says which address belongs to which proposal) or read anything back.

What it can't fix: whoever gets a shell on the **web server** can still change the site and
its donation addresses. With the split, a changed JSON is overwritten by the next push
within minutes, but a changed page or template stays until someone notices. So the web
server is now the machine to guard, and the only place left where an attack redirects
donations.

## What a run does

`ccs-back.sh` runs these steps from top to bottom:

1. **Read proposals.** Parse the frontmatter of every `.md` file in the proposals checkout
   (`lib/frontmatter.awk`). Files that don't match the expected format are logged and skipped.
2. **Check the wallet.** Its main address must be `WALLET_ADDRESS`, and it must know every
   subaddress in the state file, at the same index. A restored wallet gets its subaddresses
   re-created; a wrong wallet stops the run.
3. **Count donations.** Per subaddress, txes with at least `MIN_CONFIRMATIONS` are
   `amount-funded`; newer ones, pool included, are `amount-pending`. Donations at a
   subaddress the state file doesn't know stop the run (the state file was lost or changed).
4. **Record new proposals.** For a file seen for the first time, find the merged GitLab MR that
   added it and remember its URL. If it is funding-required, also remember when funding started.
5. **Assign addresses.** Each funding-required (`fr`) proposal without an address gets a new
   subaddress (labelled with the filename), which must come after every index already used.
6. **Fetch ideas.** Open MRs that add a single new proposal file. If GitLab is down,
   the previous list is kept.
7. **Write the JSON files.** QR codes are made fresh, then `lib/site.jq` builds the files,
   which are swapped in atomically.

| File | Does |
|---|---|
| `ccs-back.sh` | entry point, the steps above |
| `lib/common.sh` | logging, config, atomic writes, filename check |
| `lib/frontmatter.awk` | the proposal format parser (and its spec, in the comment at the top) |
| `lib/proposals.sh` | proposals to JSON, the state file |
| `lib/gitlab.sh` | ideas and merged MR lookup |
| `lib/wallet.sh` | wallet RPC, subaddresses, donation totals, QR codes |
| `lib/site.jq` | output format for ccs-front and `/projects` |
| `notify-loop.sh` | optional: runs on new txes as well as every 2 minutes (setup step 7) |

## State

Everything is recomputed on each run, except `STATE_DIR/proposals.csv`:

```
filename,gitlab_url,subaddr_index,address,funding_required_date
"fund-me.md","https://repo.getmonero.org/.../merge_requests/697",43,"8...","2026-09-08T18:06:19Z"
```

Values with a comma or a quote are quoted (`jq -r '@csv'` writes it that way).
An older `proposals.tsv` converts with `jq -rR 'split("\t") | @csv' proposals.tsv > proposals.csv`.

This file says which subaddress belongs to which proposal, so **back it up**.
The wallet can always be restored from its keys; this file cannot be recreated.

## Two ways to run it

| | A) packages on the host | B) the pinned container |
|---|---|---|
| ccs-bash's tools come from | Debian's packages, as installed today | [StageX](https://stagex.tools) packages, built from source, pinned by digest; busybox and qrencode built from pinned source here |
| The host needs | the packages below | Docker (with buildx) and `git` |
| Updates | `apt upgrade` | change the pin and rebuild (see [Changing the pin](#changing-the-pin)) |

Both run the same scripts with the same config and folders, so you can switch between them.
B is the one to use where the supply chain matters: everything in it is built from source,
what runs is exactly what the pins say, and nothing can be installed into it.

## Dependencies

**A) Packages on the host:**

```
apt install bash coreutils findutils mawk util-linux curl ca-certificates jq qrencode git logrotate
```

| Package | Used for | Notes |
|---|---|---|
| `bash` | the scripts | priority required: already on every Debian system |
| `coreutils` | `date`, `mktemp`, `base64`, `cat`, `mv`, `chmod`, `readlink`, … | priority required |
| `findutils` | `xargs` | priority required |
| `mawk` or `gawk` | `lib/frontmatter.awk` | mawk is priority required; either works |
| `util-linux` | `flock` (no overlapping runs), `runuser` (cron drops to the `ccs` user) | priority required |
| `curl` | wallet RPC and GitLab API | |
| `ca-certificates` | HTTPS to GitLab | curl only *recommends* it, so it is missing after `--no-install-recommends` |
| `jq` | all JSON, the site output | 1.6 or newer; CI tests 1.6 and 1.7 |
| `qrencode` | donation QR codes | often not installed (it wasn't on Ubuntu 22.04) |
| `git` | keeping the proposals checkout up to date (cron) | not used by `ccs-back.sh` itself |
| `logrotate` | rotating `/var/log/ccs-bash.log` | optional |
| `rsync`, `openssh-client` | pushing the output to ccs-front | only when ccs-front is on another machine |


**B) The container:** the host needs Docker with the buildx plugin (`docker-buildx-plugin` in
Docker's packages; only needed where the image is built), `git` (for the proposals checkout), optionally
`logrotate`, and `rsync` + `openssh-client` if ccs-front is on another machine. Everything
ccs-bash itself uses lives only inside the image, and all of it is built from source:

- **[StageX](https://stagex.tools) packages**, pinned by digest in `container/images`: bash,
  curl, jq, ca-certificates, and the libraries they need (musl, ncurses, openssl, zstd, zlib,
  libpng). StageX builds every package from source, starting from a tiny bootstrap, and several
  people rebuild and sign each release.
- **busybox and qrencode, built here** from their upstream source, pinned by sha256 in
  `container/sources.lock` (the same sums StageX pins). busybox gets only the 28 applets in
  `container/busybox-applets`, so there is no shell, `nc`, `wget`, ... in the image;
  qrencode is built with PNG output, which StageX's own leaves out.

The image is about 28 MB and is built in two steps by `container/build.sh`:

1. **Download** (network): the StageX images, by digest, and the source tarballs in
   `container/sources.lock`. `fetch.sh` uses plain curl and keeps a file only if its sha256
   matches.
2. **Build** (no network): `docker buildx build --network none` (buildx drives Docker's BuildKit
   engine, which is what sets every file time in the image to the commit's). The Dockerfile
   checks the sources against the lock again, compiles busybox and qrencode with StageX's
   compiler image, and puts the image together from the pinned packages. Nothing can be fetched.

The result is a **pinned image**: its hash is pinned along with everything that goes into it.
The code (the git commit), the StageX packages (their digests) and the sources (their sha256)
are fixed, so the same commit always builds to the same image hash, wherever and whenever it is
built; `build.sh` prints it. An image built elsewhere can be checked by building the same commit
and comparing hashes, and `container/check-pinned.sh` does exactly that (two clean builds from
separate clones, and one with a build cache left by another commit), in CI on every push too.

Either way, not from Debian: `monero-wallet-rpc` (from
[getmonero.org](https://www.getmonero.org/downloads/)). The tests need nothing extra, except
`zbar-tools` (`zbarimg`) for the one test that reads real QR codes back; it is skipped
without it, but required in CI.

ccs-bash doesn't use Jekyll or Markdown: it only reads the proposals' frontmatter and writes
JSON. Turning that and the proposal text into the website is ccs-front's job, so the
`jekyll build` in the cron line below belongs to ccs-front, not to ccs-bash.

## Setup

ccs-bash and ccs-front can run on the same machine or on separate ones. The steps are the
same for A and B except where marked. For two machines, steps 4 and 5 are done on the web
server instead and `ccs-bash-update` (step 6) pushes the files there, see
[ccs-front on another machine](#ccs-front-on-another-machine).

1. Run a view-only wallet with monero-wallet-rpc, as its own unprivileged user, bound to
   localhost, with a login. The options go in a config file, so the password isn't in `ps`:

   ```
   useradd --system --home-dir /var/lib/ccs/wallet --shell /usr/sbin/nologin ccs-wallet
   install -d -o ccs-wallet -g ccs-wallet -m 700 /var/lib/ccs/wallet   # the view-only wallet files go here
   install -d -g ccs-wallet -m 750 /etc/ccs-wallet
   ```

   ```
   # /etc/ccs-wallet/wallet-rpc.conf (root:ccs-wallet, 640)
   wallet-file=/var/lib/ccs/wallet/ccs
   password=<wallet password>
   daemon-address=127.0.0.1:18081
   rpc-bind-ip=127.0.0.1
   rpc-bind-port=18082
   rpc-login=ccs:<rpc password>
   log-file=/var/lib/ccs/wallet/monero-wallet-rpc.log
   ```

   ```
   # /etc/systemd/system/ccs-wallet-rpc.service, then: systemctl enable --now ccs-wallet-rpc
   [Unit]
   Description=monero-wallet-rpc (view-only) for ccs-bash
   After=network-online.target

   [Service]
   User=ccs-wallet
   Group=ccs-wallet
   ExecStart=/usr/local/bin/monero-wallet-rpc --config-file /etc/ccs-wallet/wallet-rpc.conf --non-interactive
   Restart=on-failure
   NoNewPrivileges=yes
   ProtectSystem=strict
   ReadWritePaths=/var/lib/ccs/wallet
   ProtectHome=yes
   PrivateTmp=yes

   [Install]
   WantedBy=multi-user.target
   ```

   `RPC_USER` and `RPC_PASSWORD` in ccs-bash's config are the `rpc-login` pair.

   It only holds the view key, so it cannot spend. If it leaks, the cost is donation privacy.
   With `disable-rpc-login=1`, leave `RPC_USER` empty. Keep it on the same machine as
   ccs-bash: over plain HTTP to another host, someone on the network could change its answers
   (if it must be elsewhere, reach it through an SSH tunnel).
   No `tx-notify` that starts ccs-bash itself: that needs root (to become the `ccs`
   user), so wallet-rpc would have to run as root. For updates right after a donation, see
   step 7; without it, cron picks donations up within 2 minutes.

2. Create a user and the directories. The user must be able to read the proposals checkout,
   so keep it outside `/root`:

   ```
   git clone https://github.com/plowsof/ccs-bash /opt/ccs-bash    # A and B: scripts, example config
   useradd --system --home-dir /var/lib/ccs --shell /usr/sbin/nologin ccs
   install -d -m 755 /var/lib/ccs
   install -d -o ccs -g ccs -m 755 /var/lib/ccs/state /var/lib/ccs/out
   install -o ccs -g ccs -m 644 /dev/null /var/lib/ccs/state/proposals.csv   # fresh install only
   git clone https://repo.getmonero.org/monero-project/ccs-proposals.git /var/lib/ccs/proposals
   install -d -g ccs -m 750 /etc/ccs
   install -g ccs -m 640 /opt/ccs-bash/ccs.conf.example /etc/ccs/ccs.conf    # root:ccs 640; then edit it
   ```

   The empty `proposals.csv` is for a fresh install; when moving from ccs-back it comes from the
   export instead. ccs-bash never creates it itself: if it goes missing, or loses track of
   subaddresses that hold donations, the run stops rather than give proposals new addresses.
   Restore it from your backup.

   Set `WALLET_ADDRESS` to the wallet's main address, from your own records of the wallet
   (or from `monero-wallet-cli` with the view key: `address`). It's what every run checks the
   wallet against, so take it from somewhere you trust, not just from the running wallet-rpc.

3. Install `/usr/local/bin/ccs-bash-run`, which does one run. Everything below (cron,
   moving from ccs-back) only calls `ccs-bash-run`.

   **A) on the host:**

   ```
   #!/bin/sh
   # /usr/local/bin/ccs-bash-run: one ccs-bash run, as the ccs user
   exec runuser -u ccs -- /opt/ccs-bash/ccs-back.sh /etc/ccs/ccs.conf
   ```

   **B) in the container:** get the image as `ccs-bash`, one of three ways:

   ```
   /opt/ccs-bash/container/build.sh                       # build it here
   docker save ccs-bash | ssh <host> docker load          # or build it elsewhere and copy it
   docker pull ghcr.io/plowsof/ccs-bash@sha256:<digest>   # or pull a release (for every v* tag,
   docker tag ghcr.io/plowsof/ccs-bash@sha256:<digest> ccs-bash   # CI pushes one to ghcr.io)
   ```

   Pull by the digest in the release notes, not by tag (a tag can be moved).

   Whichever way it got there, check it **before the first run**:

   ```
   docker image inspect ccs-bash --format '{{.Id}}'
   ```

   The image ID is the sha256 of the image's config, which lists the sha256 of every layer's
   content, so the same ID means exactly the same files. And the same commit always builds to
   the same ID, so take the ID to expect from somewhere other than the image itself, ideally
   two of: your own build of that commit on another machine, CI's log for that commit
   (`pinned: commit ... builds to sha256:...`), the release notes. The way the image travelled
   (ssh, a registry, a USB stick) then doesn't have to be trusted: anything changed on the way
   gives another ID. `docker load` and `docker pull` only store an image; nothing in it runs
   until `docker run`.

   ```
   #!/bin/sh
   # /usr/local/bin/ccs-bash-run: one ccs-bash run, in the pinned container, as the ccs user.
   # Read-only, no capabilities; only the folders from the config are mounted, at the same
   # paths. --network host lets it reach wallet-rpc on 127.0.0.1 without opening the wallet
   # to the docker network.
   exec docker run --rm --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges \
       --network host --user "$(id -u ccs):$(id -g ccs)" \
       -v /etc/ccs/ccs.conf:/etc/ccs/ccs.conf:ro \
       -v /var/lib/ccs/proposals:/var/lib/ccs/proposals:ro \
       -v /var/lib/ccs/state:/var/lib/ccs/state \
       -v /var/lib/ccs/out:/var/lib/ccs/out \
       ccs-bash
   ```

   Either way: `chmod 755 /usr/local/bin/ccs-bash-run`, then try it once with
   `ccs-bash-run`. `--user` (B) and `runuser` (A) both make it the `ccs` user, so the
   root-owned config stays read-only to it.

4. Point ccs-front at the output (same machine). `OUTPUT_DIR` is laid out like ccs-front's
   `_data` directory, so link or mount the **directories**:

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

   Then let ccs-front's proposal pages find their entry by `local-url` instead of by title:

   ```
   git -C ccs-front apply /opt/ccs-bash/contrib/ccs-front-local-url.patch   # _layouts/fr, wip, cp
   ```

   Matched by title (as ccs-front does today, with ccs-back too), a proposal whose title has
   `&`, `<` or a quote shows no donation box, and a merged proposal with another one's title
   can show its own box on that page. Without the patch everything works as it does now.

5. Optional `/projects` API, nginx:

   ```
   location = /projects {
       alias /var/lib/ccs/out/projects.json;
       default_type application/json;
   }
   ```

6. Put one update (pull the proposals, run ccs-bash, build the site) in a script, and run it
   from root's cron:

   ```
   #!/bin/sh
   # /usr/local/bin/ccs-bash-update (chmod 755): one update
   timeout -k 5 40 git -C /var/lib/ccs/proposals pull -q --ff-only   # GitLab down: give up
   ccs-bash-run >> /var/log/ccs-bash.log 2>&1
   cd /opt/ccs-front && jekyll build -q
   ```

   ```
   */2 * * * * /usr/local/bin/ccs-bash-update
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

   The proposals checkouts (here and ccs-front's) should not turn symlinks into real links:
   `git -C /var/lib/ccs/proposals config core.symlinks false`. A merged proposal that is a
   symlink would otherwise be copied into the built site as one, and could point the web
   server at other files. (ccs-bash itself skips symlinks.)

7. Optional, **instant updates**: a run right after a donation arrives, instead of within
   2 minutes. wallet-rpc's hook only touches a file, as wallet-rpc's own user;
   `notify-loop.sh` (as root, in place of the cron line) runs `ccs-bash-update` every 2 minutes, or
   sooner when that file is there, but never twice within 30 seconds. Lots of notifications
   (a wallet catching up after a long time offline, a flood of tiny donations) are still at
   most one run per 30 seconds, and the loop only checks that the file exists, never reads it.

   ```
   install -d -o ccs-wallet -g ccs-wallet -m 755 /var/lib/ccs-notify
   # add to /etc/ccs-wallet/wallet-rpc.conf:
   tx-notify=/usr/bin/touch /var/lib/ccs-notify/new-tx
   # and to ccs-wallet-rpc.service, so it may write there:
   ReadWritePaths=/var/lib/ccs/wallet /var/lib/ccs-notify
   ```

   Remove the cron line from step 6 and run the loop instead:

   ```
   # /etc/systemd/system/ccs-bash.service, then: systemctl enable --now ccs-bash
   [Unit]
   Description=ccs-bash, every 2 minutes and after each new tx
   After=network-online.target

   [Service]
   ExecStart=/opt/ccs-bash/notify-loop.sh /usr/local/bin/ccs-bash-update
   Restart=always

   [Install]
   WantedBy=multi-user.target
   ```

   `GAP` (30) and `EVERY` (120) seconds can be changed with `Environment=` lines. `GAP` has
   to be well below `EVERY`, or a notification only ever waits for the next regular run.

The first run on a fresh install looks up the merged MR of every proposal, which
takes a few minutes. After that, only new proposals are looked up.

### ccs-front on another machine

ccs-bash only needs the proposals repo, GitLab and the wallet; ccs-front only needs the
JSON. Running them apart keeps the wallet machine free of any incoming connection: after
each run it pushes `OUTPUT_DIR` to the web server, and the web server can only receive
those files, into one folder, and never connect back.

On the **web server** (ccs-front), create an account that can only receive the files, with
`rrsync` (shipped with Debian's rsync, 3.2.4 or newer for `-wo`). rrsync is a Python script
and Debian's rsync only suggests Python, so install both: `apt install rsync python3`.

```
useradd --system --create-home --shell /bin/sh ccs-data   # no password; the shell only runs the forced command
install -d -o ccs-data -m 755 /var/lib/ccs-data           # ideally a small filesystem of its own (or a quota)
install -d -m 755 ~ccs-data/.ssh                          # owned by root: the account can't change its own key
# ~ccs-data/.ssh/authorized_keys, owned by root, mode 644, one line with the key from the ccs-bash machine:
from="<wallet machine IP>",command="rrsync -wo -no-del -munge /var/lib/ccs-data",restrict ssh-ed25519 AAAA... ccs-bash
```

What each part stops, if the key or the wallet machine is ever taken over:

| | |
|---|---|
| `restrict` | shells, port forwarding, agent forwarding, a terminal |
| `-wo` | reading anything back, writing outside `/var/lib/ccs-data` |
| `-no-del` | deleting files |
| `-munge` | uploaded symlinks working: without it, a link named `projects.json` pointing at any readable file would get that file published by nginx |
| `from=` | using the key from anywhere but the wallet machine |
| root-owned `.ssh` | the account loosening its own key line |
| own filesystem / quota | filling the web server's disk |

Then, as in steps 4 and 5 but with this folder, use `/var/lib/ccs-data` as ccs-front's
`_data` (and for `/projects`, adding `disable_symlinks on;` to that nginx block).
ccs-front keeps its own checkout of the proposals repo for the proposal pages, and its own cron:

```
*/2 * * * * git -C /opt/ccs-front/proposals pull -q --ff-only ; cd /opt/ccs-front && jekyll build -q
```

On the **ccs-bash machine**, give the `ccs` user a key, trust exactly the web server's host
key (copied from its `/etc/ssh/ssh_host_ed25519_key.pub`, not accepted on first connect),
and push after each run:

```
install -d -o ccs -g ccs -m 700 /var/lib/ccs/.ssh
runuser -u ccs -- ssh-keygen -t ed25519 -N '' -f /var/lib/ccs/.ssh/id_ed25519
echo "<web server> ssh-ed25519 AAAA..." > /var/lib/ccs/.ssh/known_hosts    # the web server's host key
```

`ccs-bash-update` (setup step 6) then pushes instead of building the site:

```
#!/bin/sh
# /usr/local/bin/ccs-bash-update (chmod 755): one update, pushed to the web server
timeout -k 5 40 git -C /var/lib/ccs/proposals pull -q --ff-only
{ ccs-bash-run && runuser -u ccs -- rsync -a --delay-updates \
    -e "ssh -o BatchMode=yes -o StrictHostKeyChecking=yes" /var/lib/ccs/out/ ccs-data@<web server>: ; } >> /var/log/ccs-bash.log 2>&1
```

`--delay-updates` puts the new files in place only once all of them have arrived. Run it from
cron or `notify-loop.sh`, as in steps 6 and 7.

`tests/rrsync.sh` builds this setup in three containers (web server, wallet machine, another
machine) and tries everything in the table above from the wallet machine's key: commands,
port forwarding, reading back, `..` and absolute paths, `--temp-dir`, `--partial-dir`,
`--backup-dir`, `--log-file`, `--link-dest`, `--copy-dest`, `--compare-dest`, deleting,
symlinks, and the key from another machine. All are refused or stay inside the folder.
With `--loose` (rrsync alone, without the other restrictions) those checks fail, so the test
does catch them.

This can't stop a taken-over wallet machine from pushing false JSON (it is the source of the
data), and the web server stays the place to guard, see [Security](#security).

### Changing the pin

B only. For newer StageX packages, run `container/update-images.sh` (it pins every image in
`container/images` to StageX's current release), review the diff, commit it, and rebuild with
`container/build.sh`. For a newer busybox or qrencode, change its line in
`container/sources.lock` (url and sha256, e.g. the ones StageX pins) and the version in the
Dockerfile. To give busybox another applet, add it to `container/busybox-applets`.

## Moving from ccs-back

Do setup steps 1 to 3 first (A or B; with B, check the image ID before the first run).
Where upstream ccs-back's readme put things, and what replaces them:

| ccs-back | ccs-bash |
|---|---|
| proposals checkout in `/var/www/html/ccs-back/storage/app/proposals` | its own checkout in `/var/lib/ccs/proposals` (setup step 2) |
| `ccs-front/_data/*.json` symlinked to single files in `ccs-back/storage/app` | the whole `_data` directory is `/var/lib/ccs/out` (setup step 4) |
| `.env`: `RPC_URL`, `RPC_USER`, `RPC_PASSWORD`, `REPOSITORY_URL` | the same names in `/etc/ccs/ccs.conf`, plus `WALLET_ADDRESS` |
| cron: `git pull; php artisan schedule:run; jekyll build`, every minute | `ccs-bash-update` (setup step 6, or step 7) |
| nginx: `/index.php` fallback and the `location ~ \.php$` block | removed; `/projects` is the static file (setup step 5) |
| wallet-rpc, however it was started | its own user and service (setup step 1), see step 2 below |

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

   Moving the wallet to setup step 1's service: stop the old wallet-rpc (it saves the wallet
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

4. **Switch over:** replace ccs-back's cron line with ccs-bash's (setup step 6), drop
   ccs-back's `--tx-notify` script (it needs wallet-rpc to run as root; setup step 7 does the
   same without), point ccs-front at the new output directories (setup steps 4 and 5), then
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

## When something is wrong

Where to look: `/var/log/ccs-bash.log` (every run), and with step 7
`journalctl -u ccs-bash -u ccs-wallet-rpc`.

| In the log | Meaning |
|---|---|
| `curl: (22) ... error: 401` | The wallet login is wrong. Check it outside ccs-bash: `curl --digest -u 'ccs:<rpc password>' http://127.0.0.1:18082/json_rpc -d '{"jsonrpc":"2.0","id":0,"method":"get_version"}'`. The config is read by bash, so a key given twice (say an old empty `RPC_PASSWORD=` further down) quietly wins: give each key once. |
| `main address is not WALLET_ADDRESS` | Another wallet answers on that port. Nothing was written. |
| `donations at subaddress ..., which proposals.csv doesn't have` | The state file is missing entries, see [Moving from ccs-back](#moving-from-ccs-back), step 3. Nothing was written. |
| `could not fetch ideas from GitLab` | GitLab is down; the previous Ideas list is kept. The proposals `git pull` gives up after 40 seconds. |
| `skipping <file>: ...` | That proposal's frontmatter isn't read (the reason follows); it is left off the site. |

Inside the image (B) there is no shell but bash, and only the busybox commands in
`container/busybox-applets` (no `head`, `less`, `ps`, ...). To look around:
`docker run --rm -it --entrypoint bash ccs-bash`, with the same `-v` options as `ccs-bash-run`
to see what a run sees.

If your build of a commit gives another image ID than CI's: build again from a clean cache,
`NO_CACHE=1 container/build.sh`. Since #6 a warm cache gives the same ID too; `v0.1.0` and
older can pick up file times from another commit's cached build.

## Releases

Push a tag `vX.Y.Z` on `master`, or make the release on GitHub's release page (which makes
the tag). Either way the `release` workflow builds the image, runs the tests in it, runs
`check-pinned.sh`, pushes it to `ghcr.io/plowsof/ccs-bash:vX.Y.Z`, and puts the pull-by-digest
line and the image ID in the release notes (below any text written on the release page). If
it fails, the release has no notes: fix and rerun it, or delete the tag and release and make
them again. Publishing makes nothing trusted by itself: anyone can rebuild the tag and compare
IDs (step 3B).

## To do

- **Check StageX's signatures.** The images are pinned by digest; checking them against the
  signatures StageX's maintainers publish for each release would show the digests are theirs.
- **Watch the live site.** Fetch the published pages and check that every donation address
  (and QR code) on them matches the state file, to notice a changed web server within minutes.

## Tests

```
tests/run.sh             # end-to-end run on tests/fixtures with a fake wallet and GitLab
UPDATE=1 tests/run.sh    # rewrite tests/expected after an intended change, then check the diff
tests/rrsync.sh          # the two-machine rrsync setup, attacked from the wallet machine (docker)
shellcheck -x ccs-back.sh notify-loop.sh lib/*.sh tests/*.sh
```

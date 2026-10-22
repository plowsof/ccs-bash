# Setup

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
ccs-bash itself uses lives only inside the image, and all of it is built from source: see
[The pinned image](image.md).

Either way, not from Debian: `monero-wallet-rpc` (from
[getmonero.org](https://www.getmonero.org/downloads/)). The tests need nothing extra, except
`zbar-tools` (`zbarimg`) for the one test that reads real QR codes back; it is skipped
without it, but required in CI.

ccs-bash doesn't use Jekyll or Markdown: it only reads the proposals' frontmatter and writes
JSON. Turning that and the proposal text into the website is ccs-front's job, so the
`jekyll build` in `ccs-bash-update` (step 6) belongs to ccs-front, not to ccs-bash.

## Steps

ccs-bash and ccs-front can run on the same machine or on separate ones. The steps are the
same for A and B except where marked. For two machines, steps 4 and 5 are done on the web
server instead and `ccs-bash-update` (step 6) pushes the files there, see
[ccs-front on another machine](two-machines.md).

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

3. Install `/usr/local/bin/ccs-bash-run`, which does one run. Everything after this (cron,
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
   docker save ccs-bash | ssh <this host> docker load     # or build it elsewhere and copy it here
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

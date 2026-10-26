# Setup

## Dependencies

**A) Packages on the host:**

```
apt install bash coreutils findutils grep sed diffutils mawk util-linux curl ca-certificates jq git logrotate
```

| Package | Used for | Notes |
|---|---|---|
| `bash`, `coreutils`, `findutils`, `grep`, `sed`, `diffutils`, `util-linux` | the scripts, `xargs`, `diff` (images), `flock`, `runuser` | priority required |
| `mawk` or `gawk` | `lib/frontmatter.awk` | either works |
| `curl`, `ca-certificates` | wallet RPC, GitLab API | curl only recommends `ca-certificates` |
| `jq` | all JSON | 1.6 or newer |
| `git` | the proposals checkout | |
| `logrotate` | the log | optional |
| `rsync`, `openssh-client` | pushing the site to the web server, and the state to the backup machine | |

**B) The container:** Docker with buildx, `git`, optionally `logrotate`, and `rsync` +
`openssh-client`. Where the image is built, also `gpg` and `jq`. Everything
ccs-bash runs is inside the image ([The pinned image](image.md)).

Either way: `monero-wallet-rpc` from [getmonero.org](https://www.getmonero.org/downloads/).

## Steps

The same for A and B except where marked. The site itself (ccs-front-bash), the web server and the
push: [the handover](handover.md), steps 3–9.

1. **The wallet:** monero-wallet-rpc, view-only, as its own user, on localhost, with a login.
   Options go in a file so the password isn't in `ps`:

   ```
   useradd --system --home-dir /var/lib/ccs/wallet --shell /usr/sbin/nologin ccs-wallet
   install -d -o ccs-wallet -g ccs-wallet -m 700 /var/lib/ccs/wallet   # the wallet files
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

   `rpc-login` is `RPC_USER`/`RPC_PASSWORD` in ccs-bash's config. Keep wallet-rpc on the same
   machine (plain HTTP can be tampered with). Its `tx-notify` only touches a file: step 5.

2. **User, folders, config:**

   ```
   git clone https://github.com/plowsof/ccs-bash /opt/ccs-bash
   git -C /opt/ccs-bash checkout v0.2.20     # the release you run (the handover's releases table), not master
   useradd --system --home-dir /var/lib/ccs --shell /usr/sbin/nologin ccs
   useradd --system --no-create-home --shell /usr/sbin/nologin ccs-git   # owns the proposals checkout
   install -d -m 755 /var/lib/ccs
   install -d -o ccs -g ccs -m 755 /var/lib/ccs/state /var/lib/ccs/out
   install -o ccs -g ccs -m 644 /dev/null /var/lib/ccs/state/proposals.csv   # fresh install only
   install -d -o ccs-git -g ccs-git -m 755 /var/lib/ccs/proposals
   runuser -u ccs-git -- env HOME=/ git clone -q -c core.symlinks=false \
       https://repo.getmonero.org/monero-project/ccs-proposals.git /var/lib/ccs/proposals
   install -d -g ccs -m 750 /etc/ccs
   install -g ccs -m 640 /opt/ccs-bash/ccs.conf.example /etc/ccs/ccs.conf    # then edit it
   ```

   `core.symlinks=false`: a merged symlink stays a plain file, so it can't point the web server
   at other files. (`HOME=/` because root's isn't readable to other users.)

   Moving from ccs-back, `proposals.csv` comes from the [export](handover.md#2-ccs-bash-and-its-state-the-backend) instead.
   ccs-bash never creates it: if it is missing or incomplete, runs stop; restore your backup.

   Take `WALLET_ADDRESS` from your own records (or `address` in `monero-wallet-cli`), not from
   the running wallet-rpc: it's what every run checks the wallet against.

3. **`/usr/local/bin/ccs-bash-run`**, one run (`chmod 755`, then try it). Everything later calls it.

   **A)**

   ```
   #!/bin/sh
   exec runuser -u ccs -- /opt/ccs-bash/ccs-back.sh /etc/ccs/ccs.conf
   ```

   **B)** Get the image as `ccs-bash`:

   ```
   /opt/ccs-bash/container/build.sh                       # build it here
   docker save ccs-bash | ssh <this host> docker load     # or build elsewhere and copy it
   docker pull ghcr.io/plowsof/ccs-bash@sha256:<digest>   # or a release, by the digest in its notes
   docker tag ghcr.io/plowsof/ccs-bash@sha256:<digest> ccs-bash
   ```

   **Before the first run**, compare `docker image inspect ccs-bash --format '{{.Id}}'` with the
   attested one ([upgrading](handover.md#upgrading)): the same commit gives the same ID anywhere.
   The run script names that ID, never a tag (a Docker cleanup can remove a tag, and `docker run`
   would then try Docker Hub), and a stopped container keeps the image itself:
   `docker create --name ccs-bash-keep --network none <ID>`.

   ```
   #!/bin/sh
   # read-only, no capabilities, only the config's folders; host network to reach 127.0.0.1
   exec docker run --rm --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges \
       --network host --user "$(id -u ccs):$(id -g ccs)" \
       -v /etc/ccs/ccs.conf:/etc/ccs/ccs.conf:ro \
       -v /var/lib/ccs/proposals:/var/lib/ccs/proposals:ro \
       -v /var/lib/ccs/state:/var/lib/ccs/state \
       -v /var/lib/ccs/out:/var/lib/ccs/out \
       --pull never sha256:<the image ID you checked>
   ```

4. **One update** (pull, run, build the site, push it), from root's cron. Root only starts the
   steps: git and the site builder read merged proposals, so they run as their own users. The
   script: [the handover](handover.md#9-the-update), step 9.

   ```
   */2 * * * * /usr/local/bin/ccs-bash-update
   ```

   Overlapping runs are skipped. Rotate the log (`/etc/logrotate.d/ccs-bash`):

   ```
   /var/log/ccs-bash.log {
       weekly
       rotate 4
       compress
       missingok
       notifempty
   }
   ```

5. **Optional, instant updates.** wallet-rpc's hook only touches a file; `notify-loop.sh`
   (root, instead of the cron line) runs `ccs-bash-update` every 2 minutes, or sooner when the
   file appears, but at most once per 30 seconds however many notifications come.

   ```
   install -d -o ccs-wallet -g ccs-wallet -m 755 /var/lib/ccs-notify
   # in /etc/ccs-wallet/wallet-rpc.conf:
   tx-notify=/usr/bin/touch /var/lib/ccs-notify/new-tx
   # in ccs-wallet-rpc.service:
   ReadWritePaths=/var/lib/ccs/wallet /var/lib/ccs-notify
   ```

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

   `Environment=GAP=30 EVERY=120` changes the timings; keep `GAP` well below `EVERY`.

The first run looks up the merged MR of every proposal, which takes a few minutes.

## Backing up the state

The state (`proposals.csv`, and each retired wallet's file) can't be made again: each new version
goes to another machine, to an account whose key runs only `contrib/ccs-backup-receive`. It keeps
every version (`proposals-<UTC time>.csv`), never overwriting or deleting one, so a taken-over
backend can't destroy them; `deposits.csv`, a cache, as one copy replaced only by one with every
deposit it has.

On the **backup machine** (any one; the file is a few KB):

```
useradd --system --create-home --home-dir /home/ccs-backup --shell /bin/sh ccs-backup
passwd -l ccs-backup
install -d -o ccs-backup -g ccs-backup -m 700 /var/lib/ccs-backup
install -m 755 ccs-backup-receive /usr/local/bin/              # from ccs-bash's contrib/
install -d -m 755 /etc/ssh/authorized_keys
# root-owned and outside the account's home (which it owns), so it can't change it; the backend's key
# below, usable only from the backend's address (its from=, as the web server's push key)
echo 'from="<backend IP>",restrict,command="/usr/local/bin/ccs-backup-receive" ssh-ed25519 AAAA... ccs-bash state backup' \
    > /etc/ssh/authorized_keys/ccs-backup
```

and in `/etc/ssh/sshd_config` (at the end), then `systemctl reload ssh`, so sshd reads no other key
file for it:

```
Match User ccs-backup
    AuthorizedKeysFile /etc/ssh/authorized_keys/%u
```

On the **backend**: a key (`ssh-keygen -t ed25519 -N '' -f /root/.ssh/ccs-backup_ed25519`, its
`.pub` in the line above) and the backup machine's host key in `known_hosts`. [The update
script](handover.md#9-the-update) sends each new version (`ccs-backup: kept …` in the log).
Restoring: [troubleshooting](troubleshooting.md#restore-the-state).

## Proposals on Forgejo (disroot, Codeberg) instead of GitLab

Two changes on the backend:

1. **The API**, in `/etc/ccs/ccs.conf`:

   ```
   REPOSITORY_URL=https://git.disroot.org/api/v1/repos/<owner>/<repo>
   ```

   (`/api/v1/repos/` is what makes it Forgejo or Gitea; public, read without a token.)

2. **The checkout**, so `ccs-bash-update` pulls from there:

   ```
   runuser -u ccs-git -- env HOME=/ git -C /var/lib/ccs/proposals \
       remote set-url origin https://git.disroot.org/<owner>/<repo>.git
   ```

   Pushed from the GitLab one (the same history), the next pull carries on; else clone it afresh.

Ideas become its open pull requests, and newly merged proposals link to theirs; known ones keep
their GitLab link in `proposals.csv` (imported with their numbers: rewrite them with
`sed -i 's#https://repo.getmonero.org/monero-project/ccs-proposals/-/merge_requests/#https://git.disroot.org/<owner>/<repo>/pulls/#'`,
the loop paused, a copy kept). The site's words ("GitLab", Submit Idea) are ccs-front-hugo's.
Going back: the old `REPOSITORY_URL` and remote.

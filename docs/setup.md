# Preparing the machines

What each machine's host needs before its compose runs ([docker](docker.md)): the accounts, the
folders, the config and the key files. Everything else runs in the attested images. The order
across the machines: [the handover](handover.md).

## The backend

**Packages:** Docker with buildx (on Debian, Docker's own packages: bookworm's `docker.io` has no
buildx) and docker compose, with Docker's own image store, not its containerd one (where an image
ID isn't the attested one): `{"features": {"containerd-snapshotter": false}}` in
`/etc/docker/daemon.json`, before building. And `git` (the proposals checkout, the releases),
`jq` and `curl` (`ccs`, and the migration from ccs-back), `gpg` (checking the releases' and the
list's signatures), `openssh-client` (the push and backup keys):

```
apt install git jq curl gpg openssh-client
```

1. **The wallet's files:** its own user and folder, and its options in a file, so the password
   isn't in `ps` (the compose's `wallet-rpc` reads it; the binary is the image's,
   `contrib/docker/backend/wallet-rpc`):

   ```
   useradd --system --home-dir /var/lib/ccs/wallet --shell /usr/sbin/nologin ccs-wallet
   install -d -o ccs-wallet -g ccs-wallet -m 700 /var/lib/ccs/wallet   # the view-only wallet's files
   install -d -g ccs-wallet -m 750 /etc/ccs-wallet
   ```

   ```
   # /etc/ccs-wallet/wallet-rpc.conf (root:ccs-wallet, 640)
   wallet-file=/var/lib/ccs/wallet/ccs
   password=<wallet password>
   daemon-address=host.docker.internal:18089
   rpc-bind-port=18082
   rpc-login=ccs:<rpc password>
   log-file=/var/lib/ccs/wallet/monero-wallet-rpc.log
   ```

   `daemon-address`: monerod's restricted RPC where the containers reach it ([the
   handover, 1](handover.md#1-monerod-and-monero-wallet-rpc-the-backend)). `rpc-login` is
   `RPC_USER`/`RPC_PASSWORD` in ccs-bash's config. The wallet's RPC is on the compose's internal
   network only, reached by ccs-bash alone.

2. **Accounts, folders, config, the proposals:**

   ```
   git clone https://github.com/plowsof/ccs-bash /opt/ccs-bash
   git -C /opt/ccs-bash checkout <commit>    # the one contrib/release/verify prints for the release you run (the handover, "Deploying a set", 1-2): not the tag, which can move; not master
   useradd --system --home-dir /var/lib/ccs --shell /usr/sbin/nologin ccs
   useradd --system --no-create-home --shell /usr/sbin/nologin ccs-git   # owns the proposals checkout
   useradd --system --no-create-home --shell /usr/sbin/nologin ccs-front # makes the site
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

   And `ccs`, for looking at it all as ccs-back's artisan commands did
   ([troubleshooting](troubleshooting.md#looking)): `ln -s /opt/ccs-bash/contrib/ccs /usr/local/bin/ccs`
   (a link: it reads its docs from the checkout, which each upgrade moves to the new release).

3. **The design and the site builder's files:** the design's release, unpacked where the
   compose's `front` reads it; its sha256 the attested one ([the releases](handover.md#the-releases)):

   ```
   v=<the design's release>
   curl -fLO https://github.com/plowsof/ccs-front-hugo/releases/download/$v/ccs-front-hugo-$v.zip
   sha256sum ccs-front-hugo-$v.zip           # the attested sha256
   rm -rf /opt/ccs-front-hugo/public && install -d -m 755 /opt/ccs-front-hugo/public
   unzip -q ccs-front-hugo-$v.zip -d /opt/ccs-front-hugo/public
   echo "$v <its sha256>" > /opt/ccs-front-hugo/VERSION      # for ccs status
   install -d -m 755 /etc/ccs-front                           # the signed list: signed-list.md
   ```

   It stays root's: the site builder only reads it. A new design is a new release, unpacked the
   same way.

Then the compose: [docker, setting it up](docker.md#setting-it-up).

## The backup machine

The state (`proposals.csv`, and each retired wallet's file) can't be made again: each new version
goes to another machine, to an account whose key runs only `contrib/ccs-backup-receive`, in the
web server compose's `backup` service ([docker](docker.md#the-web-server-in-docker)). It keeps
every version (`proposals-<UTC time>.csv`), never overwriting or deleting one, so a taken-over
backend can't destroy them; `deposits.csv`, a cache, as one copy replaced only by one with every
deposit it has.

On the **backup machine** (any but the web server, whose root could rewrite every copy as well as
the site; the files are a few KB):

```
install -d -m 755 /var/empty                                    # its home: root's and empty
useradd --system --no-create-home --home-dir /var/empty --shell /bin/sh ccs-backup
passwd -l ccs-backup
install -d -o ccs-backup -g ccs-backup -m 700 /var/lib/ccs-backup
# the retired wallets it keeps a record of, one name a line: you add each when you retire it
# (handover, "Retiring a wallet"), so a taken-over backend can't add a wallet of its own
install -d -m 755 /etc/ccs-backup && install -m 644 /dev/null /etc/ccs-backup/retired-names
install -d -m 755 /etc/ssh/authorized_keys
# root-owned and outside the account's home (which it owns), so it can't change it; the backend's key
# below, usable only from the backend's address (its from=, as the web server's push key)
echo 'from="<backend IP>",restrict,command="/usr/local/bin/ccs-backup-receive" ssh-ed25519 AAAA... ccs-bash state backup' \
    > /etc/ssh/authorized_keys/ccs-backup
```

The backend's key: `/etc/ccs/backup/id_ed25519` ([docker](docker.md#setting-it-up), step 2), its
`.pub` in the line above. Restoring: [troubleshooting](troubleshooting.md#restore-the-state).

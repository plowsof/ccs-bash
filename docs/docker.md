# The backend in Docker

[`contrib/docker/backend/compose.yml`](../contrib/docker/backend/compose.yml) runs the backend's
update ([the handover](handover.md#9-the-update), step 9) as one service a stage, and
monero-wallet-rpc, instead of the host's loop ([setup](setup.md) steps 1 and 4-5). The host keeps
its users, folders and config (setup steps 2-3), so either one can run them, never both. The
testnet runs it ([the testnet](testnet.md)).

| Service | Its image | Its user | Its network | What it may write |
|---|---|---|---|---|
| `wallet-rpc` | getmonero.org's release ([wallet-rpc/Dockerfile](../contrib/docker/backend/wallet-rpc/Dockerfile)) | `ccs-wallet` | the host's: 127.0.0.1, an external monerod | the wallet |
| `pull` | ccs-bash's | `ccs-git` | out to the forge | the proposals checkout |
| `ccs-bash` | ccs-bash's | `ccs` | the host's: the wallet, the forge's API | the state, the JSON |
| `backup` | ccs-bash's | `ccs` | out to the backup machine | nothing (the state read-only) |
| `front` | ccs-front-bash's | `ccs-front` | **none** | the site |
| `push` | ccs-bash's | `ccs` | out to the web server | the copy of what was pushed |

Every one read-only, no capabilities, `no-new-privileges`, only its folders. None has the Docker
socket: no stage can start, stop or reach into another. They take turns through the run folder
(`/var/lib/ccs/run`): each stage's `done` (the last run it finished), `status`, and pipes that
wake the next ([`step`](../contrib/docker/backend/step)). A run starts every 2 minutes, at once on
a new transaction (the wallet's `tx-notify`) or on `ccs proposal:process`. The images by ID,
never pulled: ccs-bash's and ccs-front-bash's as [their releases](handover.md#the-releases) attest
them (the same checks: [upgrading](handover.md#upgrading)); ccs-bash's carries git, rsync and
openssh (StageX, signatures checked as its other packages) for the pull, the push and the backups.
The wallet's is the one image not StageX's: monero isn't packaged there, and its release is built
for glibc; its archive is checked against getmonero.org's signed hashes (kept in the repository),
the signature against binaryFate's key by fingerprint.

## Setting it up

On the backend, as root, after [setup](setup.md) steps 2-3 (users, folders, config; step 1's
wallet files and `wallet-rpc.conf`, not its service):

1. **The images.** ccs-bash's and ccs-front-bash's: their attested IDs, built here
   (`container/build.sh`, as for the host setup). The wallet's:
   `docker build -q contrib/docker/backend/wallet-rpc` (its ID: the output).
2. **The log, writable by the stages:** `groupadd --system ccs-log; chgrp ccs-log
   /var/log/ccs-bash.log; chmod 664 /var/log/ccs-bash.log`, and `create 664 root ccs-log` in
   `/etc/logrotate.d/ccs-bash`.
3. **The backup key, for ccs:** its `id_ed25519` and the backup machine's line in `known_hosts`
   in `/etc/ccs/backup/` (`ccs`, 700; the files 600). The push key stays in ccs's `~/.ssh`.
4. **`.env`** beside `compose.yml` (root's, 600), from
   [`env.example`](../contrib/docker/backend/env.example): the three image IDs, the users'
   `uid:gid` (`id -u ccs`, `id -g ccs`...), the log's group, the push and backup accounts.
5. **The run folder:** `install -d -m 755 /var/lib/ccs/run`, then
   `docker compose --profile init run --rm -T init`; `chown ccs-git /var/lib/ccs/pull-ok`.
6. **ccs-watch** stays on the host for now: its timer as before, and after each push
   `contrib/docker/backend/watch-after-push`, as ccs, from a unit:

   ```
   [Service]
   User=ccs
   SupplementaryGroups=ccs-log
   ExecStart=/opt/ccs-bash/contrib/docker/backend/watch-after-push https://<site>
   Restart=always
   ```

7. `docker compose up -d`; `ccs status` names the services and each stage's last run.

**From the host setup:** between runs, `systemctl disable --now ccs-bash ccs-wallet-rpc`; copy the
backup's sums (`/var/lib/ccs/backup-sent*` to `/var/lib/ccs/run/backup/sent-<file>`, so nothing is
sent again); then step 7. **Back:** `docker compose down`, `systemctl enable --now
ccs-wallet-rpc ccs-bash`.

## Running it

`ccs` works as before ([looking](troubleshooting.md#looking)): `ccs proposal:process` starts a
run at once and prints it; `ccs status`, `ccs log` read the same log. `docker compose logs -f
<service>` shows one stage's output. A stage that fails says so in its `status`, and the run's
result goes to ccs-watch as the host loop's did (three failed runs alert).

- **Upgrading:** the new attested IDs in `.env`, between runs (`ccs status`: no run going),
  `docker compose up -d`. A new monero: its `hashes.txt` (signed) and the version and sum in
  `wallet-rpc/Dockerfile`, then build it.
- **A design upgrade** needs nothing more: `front` mounts `/opt/ccs-front-hugo`, so a renamed
  `public` is seen. Likewise the site: `push` mounts `/var/lib/ccs/www`, not `www/site`, which
  ccs-front-bash replaces each run (a mount of a folder keeps the one it was given).
- **The proposals checkout replaced** ([another forge](setup.md#proposals-on-another-forge)):
  `docker compose up -d --force-recreate pull ccs-bash front` after, for the same reason.

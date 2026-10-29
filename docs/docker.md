# The backend in Docker

<p align="center"><img src="docker-design.svg" width="900" alt="The backend in Docker: pull, ccs-bash, front and backup, push and watch take turns through the run folder, each in its own container with its own user, network, folders and secret; ccs-bash and the wallet alone share an internal network; front has none; the web server and the backup machine are unchanged"></p>

[`contrib/docker/backend/compose.yml`](../contrib/docker/backend/compose.yml) runs the backend's
update ([the handover](handover.md#9-the-update), step 9), and ccs-watch, as one service a stage,
and monero-wallet-rpc, instead of the host's loop ([setup](setup.md) steps 1 and 4-5). The host
keeps its users, folders and config (setup steps 2-3), so either one can run them, never both.
The testnet runs it ([the testnet](testnet.md)).

## The design

It is [the recommended architecture](handover.md) unchanged: the backend makes the whole site and
only connects out; the web server's gate checks every page; ccs-watch checks the live ones; the
state goes to the backup machine. Docker only changes the backend's side: each step in a container
of its own, so a fault in one (a hostile proposal file against ccs-front-bash, say) reaches only
that container's folders, network and secret.

| Service | Its image | Its user | Its network | What it holds or may write |
|---|---|---|---|---|
| `wallet-rpc` | getmonero.org's release ([wallet-rpc/Dockerfile](../contrib/docker/backend/wallet-rpc/Dockerfile)) | `ccs-wallet` | `wallet` (internal), `monerod` (out) | **the wallet** |
| `pull` | ccs-bash's | `ccs-git` | out: the forge | the proposals checkout |
| `ccs-bash` | ccs-bash's | `ccs` | `wallet`, out: the forge's API | the state, the JSON |
| `backup` | ccs-bash's | `ccs` | out: the backup machine | **the backup key**; nothing written |
| `front` | ccs-front-bash's | `ccs-front` | **none** | the site |
| `push` | ccs-bash's | `ccs` | out: the web server | **the push key**; the copy of what was pushed |
| `watch` | ccs-bash's | `ccs` | out: the web server, the alerts | **alert.conf**; its own state |

- **Every one** read-only, no capabilities, `no-new-privileges`, a numeric user, only its folders.
  None has the Docker socket: no stage can start, stop or reach into another.
- **The wallet's RPC** is on the `wallet` network only, which is internal: ccs-bash is the one
  other container on it, and neither reaches out through it (the wallet has its own way out to
  monerod; ccs-bash, to the forge). Its login stays in `wallet-rpc.conf`.
- **Why a container a stage, not one:** each secret is in the one container that needs it, and
  the one that reads untrusted input (front: proposal files) has no network and no secret. One
  container for the whole update would put the wallet's RPC, the push key and the backup key
  beside ccs-front-bash. The price is the run folder, below.
- **How they take turns** ([`step`](../contrib/docker/backend/step)): the run folder
  (`/var/lib/ccs/run`) has each stage's `done` (the last run it finished), `status`, `at`, and
  pipes that wake the next; and the push's lock, which the watch shares. The pipes only make it
  quicker: a waiting stage looks at the others' `done` every 5 seconds anyway, so a line written
  while nothing read it costs seconds, never a run. A run starts every 2 minutes, at once on a new
  transaction (the wallet's `tx-notify`) or on `ccs proposal:process`.
- **The images** by ID, never pulled: ccs-bash's and ccs-front-bash's as
  [their releases](handover.md#the-releases) attest them (the same checks:
  [upgrading](handover.md#upgrading)). ccs-bash's carries git and its https transport, ssh and
  rsync (StageX, signatures checked as its other packages), and of those packages nothing else: no
  sshd, ssh agent or key tools, no git server ([`container/Dockerfile`](../container/Dockerfile),
  checked by `tests/image.sh`). The wallet's is the one image not StageX's: monero isn't packaged
  there, and its release is built for glibc; its archive is checked against getmonero.org's
  signed hashes (kept in the repository), the signature against binaryFate's key by fingerprint.
- **Building** is on the backend (`container/build.sh`), or anywhere, then copied: `docker save
  <ID> | ssh <backend> docker load` keeps the ID, which is what's checked
  ([setup](setup.md), step 3).
- **The log:** every container's output to journald under one name, `ccs`: a run's lines in
  order, whichever stage said them, rotated by journald (`journalctl -t ccs`). `ccs log` and
  `ccs status` read it.
- **Health:** each stage's healthcheck is that it finished a run lately (the watch: a check);
  `docker compose ps` shows it. A failed run still counts as finished: ccs-watch alerts on three.

## A host whose monerod is on its own 127.0.0.1

The wallet on the `wallet` network reaches monerod (`daemon-address` in `wallet-rpc.conf`) over
its `monerod` network: another machine, or this one on an address containers reach. A monerod
(or alert.conf's proxy and bot) listening on the host's 127.0.0.1 only, as on the testnet, isn't
one of those: [`compose.host.yml`](../contrib/docker/backend/compose.host.yml) puts the wallet,
ccs-bash and the watch on the host's network instead, the wallet's RPC on 127.0.0.1, as the host
setup has them; the other stages keep theirs. In `.env`: `COMPOSE_FILE=compose.yml:compose.host.yml`;
in `ccs.conf`, `RPC_URL=http://127.0.0.1:18182/json_rpc` (without it, `http://wallet-rpc:18182/json_rpc`).

## Setting it up

On the backend, as root, after [setup](setup.md) steps 2-3 (users, folders, config; step 1's
wallet files and `wallet-rpc.conf`, not its service):

1. **The images.** ccs-bash's and ccs-front-bash's: their attested IDs, built here
   (`container/build.sh`, as for the host setup) or loaded. The wallet's:
   `docker build -q contrib/docker/backend/wallet-rpc` (its ID: the output).
2. **The backup key, for ccs:** its `id_ed25519` and the backup machine's line in `known_hosts`
   in `/etc/ccs/backup/` (`ccs`, 700; the files 600). The push key stays in ccs's `~/.ssh`.
3. **`ccs.conf`'s `RPC_URL`:** `http://wallet-rpc:18182/json_rpc` (or 127.0.0.1, above), and
   `/etc/ccs/alert.conf` readable by ccs (the watch runs as ccs, as ccs-watch's unit did).
4. **`.env`** beside `compose.yml` (root's, 600), from
   [`env.example`](../contrib/docker/backend/env.example): the three image IDs, the users'
   `uid:gid` (`id -u ccs`, `id -g ccs`...), the push and backup accounts, the site's address.
5. **The run folder:** `install -d -m 755 /var/lib/ccs/run`, then
   `docker compose --profile init run --rm -T init`; `chown ccs-git /var/lib/ccs/pull-ok`.
6. `docker compose up -d`; `ccs status` names the services, their health and each stage's last
   run.

**From the host setup:** between runs, `systemctl disable --now ccs-bash ccs-wallet-rpc
ccs-watch.timer`; copy the backup's sums (`/var/lib/ccs/backup-sent*` to
`/var/lib/ccs/run/backup/sent-<file>`, so nothing is sent again); then step 6. **Back:** `docker
compose down`, `systemctl enable --now ccs-wallet-rpc ccs-bash ccs-watch.timer`.

**From v0.2.30's compose** (the host's log file, `watch-after-push`): `systemctl disable --now
ccs-watch-after-push ccs-watch.timer` and remove the unit; step 5's `init` again (the watch's
folder, the lock); `.env`'s `CCS_SITE_URL` (and `COMPOSE_FILE`, above), `LOG_GID` out; then
`docker compose up -d`. `/var/log/ccs-bash.log` keeps the runs before; the `ccs-log` group and its
logrotate line can go.

## Running it

`ccs` works as before ([looking](troubleshooting.md#looking)): `ccs proposal:process` starts a
run at once and prints it; `ccs status`, `ccs log` read the journal. `journalctl -t ccs -f`
follows every stage; `docker compose logs -f <service>` one. A stage that fails says so in its
`status`, and the run's result goes to the watch (three failed runs alert).

- **Upgrading:** the new attested IDs in `.env`, between runs (`ccs status`: no run going),
  `docker compose up -d`. A new monero: its `hashes.txt` (signed) and the version and sum in
  `wallet-rpc/Dockerfile`, then build it.
- **A design upgrade** needs nothing more: `front` mounts `/opt/ccs-front-hugo`, so a renamed
  `public` is seen. Likewise the site: `push` mounts `/var/lib/ccs/www`, not `www/site`, which
  ccs-front-bash replaces each run (a mount of a folder keeps the one it was given).
- **The proposals checkout replaced** ([another forge](setup.md#proposals-on-another-forge)):
  `docker compose up -d --force-recreate pull ccs-bash front` after, for the same reason.

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
wallet files and `wallet-rpc.conf`, not its service). The config files, filled in as far as
they are public: [contrib/examples/backend](../contrib/examples/backend/README.md), which also
says how to install them; `ccs config:check` then says what is missing or wrong.

1. **The images.** ccs-bash's and ccs-front-bash's: their attested IDs, built here
   (`container/build.sh`, as for the host setup) or loaded. The wallet's:
   `docker build -q contrib/docker/backend/wallet-rpc` (its ID: the output).
2. **The backup key, for ccs:** its `id_ed25519` and the backup machine's line in `known_hosts`
   in `/etc/ccs/backup/` (`ccs`, 700; the files 600). The push key stays in ccs's `~/.ssh`.
3. **`ccs.conf`'s `RPC_URL`:** `http://wallet-rpc:18182/json_rpc` (or 127.0.0.1, above), and
   `/etc/ccs/alert.conf` readable by ccs (the watch runs as ccs, as ccs-watch's unit did).
4. **`.env`** beside `compose.yml` (root's, 600), from the examples (or
   [`env.example`](../contrib/docker/backend/env.example)): the three image IDs, the users'
   `uid:gid` (`id -u ccs`, `id -g ccs`...), the wallet's port, the push and backup accounts, the
   site's address.
5. **The run folder:** `install -d -m 755 /var/lib/ccs/run`, then
   `docker compose --profile init run --rm -T init`; `chown ccs-git /var/lib/ccs/pull-ok`.
6. `docker compose up -d`, then `ccs config:check` until nothing fails (it asks the wallet
   through ccs-bash's container, so after the start); `ccs status` names the services, their
   health and each stage's last run.

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

## The web server in Docker

<p align="center"><img src="docker-web-design.svg" width="900" alt="The web server in Docker: nginx on the host serves /var/lib/ccs-data as before; the gate's sshd on port 2223 lets the push key run only ccs-receive, the backup sshd on 2224 the backup key only ccs-backup-receive, both from the backend's address only; the heartbeat alerts when pushes stop; one attested StageX image"></p>

[`contrib/docker/web/compose.yml`](../contrib/docker/web/compose.yml) runs the web server's side
of [two machines](two-machines.md), the gate and the backup receiver, from one image, the gate's
([`container/gate.Dockerfile`](../container/gate.Dockerfile)), instead of the host's sshd and
`/usr/local/bin` scripts. **nginx stays on the host**, serving `/var/lib/ccs-data` as before: the
gate writes the same folder, so nginx's config doesn't change. The host keeps the accounts' ids,
folders, key files and `/etc/ccs-gate` (two-machines' setup), so either one can run them, never
both on the same port.

| Service | Its user | Port | Its capabilities | What it may write |
|---|---|---|---|---|
| `gate` | sshd as root; the forced command as `ccs-data` | 2223 | `SETUID`, `SETGID`, `SYS_CHROOT` | staging, the live site, the gate's state, its log |
| `backup` | sshd as root; the forced command as `ccs-backup` | 2224 | the same | the backups |
| `heartbeat` | `ccs-data` | none | none | the gate's state, its log |

- **The image:** StageX by digest (signatures checked), sources by sha256, built as ccs-bash's,
  reproducible, attested in the same release (`contrib/release/build ccs-bash vX` builds both; its
  second line is `ccs-gate-vX`; `contrib/release/verify ccs-gate-vX`). GNU userland, as the gate
  was written and tested for; sshd (no ssh client, sftp or agent); Python; git; and the QR reader's
  libraries, with no ImageMagick: libzbar built here (StageX publishes none; one undefined
  behaviour in it fixed, which crashed every scan under clang), on pixels libpng, libturbojpeg or
  giflib decode; qrencode built with PNG output, as ccs-front-bash builds it, so its QR codes are
  the backend's, pixel for pixel. About 160 MB.
- **sshd** as root, read-only, every capability dropped but the three it can't log anyone in
  without (`compose.yml` says why each), `no-new-privileges`. One sshd a service, one user each
  (`AllowUsers`), its forced command (`ForceCommand`, and the key file's `command=`); keys only, in
  the host's root-owned key files (`/etc/ssh/authorized_keys`, with their `from=`); no shell,
  terminal, forwarding, agent, tunnel, environment or subsystem
  ([`sshd_config`](../contrib/docker/web/sshd_config)). On the host's network, so `from=` sees the
  backend's own address (Docker's published ports would show it Docker's for IPv6).
- **Its host key** is its own (`/etc/ccs-gate/ssh`, made by `init` the first time), not the
  host's: the backend's `known_hosts` gets a line for `[<web server>]:2223` and `:2224`.
- **The log:** sshd's lines to journald (`journalctl -t ccs-web`); the gate's own to
  `/var/log/ccs-web/ccs-gate.log` (a folder mounted: a rotated file would stay the old one).
- **Tests:** `tests/gate.sh` with `GATE_IMAGE` runs every check of the gate with this image as the
  web server; `tests/gate-image.sh`, inside it, its QR reader and tools; `tests/web.sh` attacks
  its sshd, run as `compose.yml` runs it, from the backend's keys and from another machine.

### Setting it up

On the web server, as root, after two-machines' setup of the accounts, folders, key files and
`/etc/ccs-gate` (the host's sshd lines for them can stay until the switch):

1. **The image:** its attested ID (`contrib/release/verify ccs-gate-vX`), built here
   (`container/build.sh ccs-gate gate.Dockerfile`) or loaded (`docker save <ID> | ssh <web
   server> docker load`).
2. **Folders:** `install -d -m 700 /etc/ccs-gate/ssh`; `install -d -o ccs-data -m 755
   /var/log/ccs-web`.
3. **`.env`** beside `compose.yml` (root's, 600), from
   [`env.example`](../contrib/docker/web/env.example): the image ID, `id -u ccs-data`:`id -g
   ccs-data` and the same for `ccs-backup`.
4. `docker compose --profile init run --rm -T init`: it prints the host key.
5. **The firewall:** 2223 and 2224 open to the backend's address only (`ufw allow from <backend>
   to any port 2223,2224 proto tcp`, and a cloud provider's list).
6. `docker compose up -d`; `docker compose ps` shows the three healthy.
7. **The backend:** `[<web server>]:2223 <key>` and `[<web server>]:2224 <key>` in ccs's
   `~/.ssh/known_hosts` and in the backup key's (`/etc/ccs/backup/known_hosts`), then in the
   backend compose's `.env` `CCS_PUSH_PORT=2223` and `CCS_BACKUP_PORT=2224`, `docker compose up -d`
   between runs (the host loop: `-p 2223` in its push's `ssh`, `-p 2224` in its backup's). The next
   run pushes through the container: its line in `/var/log/ccs-web/ccs-gate.log`, ccs-watch's check
   after it.
8. **Then** the host's: `systemctl disable --now ccs-heartbeat.timer`; the `Match User ccs-data`
   and `ccs-backup` blocks out of `/etc/ssh/sshd_config` (`sshd -t`, `systemctl reload ssh`), so
   port 22 no longer takes those keys. **Back:** the blocks and the timer again, the backend's port
   back to 22, `docker compose down`.

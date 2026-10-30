# The testnet

https://ccs.monerodevs.org runs this setup on Monero's testnet, so that each release and each step
of [the handover](handover.md) runs somewhere before ccs.getmonero.org. The set it runs: [the
releases](handover.md#the-releases). Nothing here is part of the setup: don't copy it.

**As of 2026-10-30 it runs in mirror mode** (`MIRROR_URL`, [ccs.conf.example](../ccs.conf.example)):
on mainnet, with the real CCS's view-only wallet, every proposal's address taken from
ccs.getmonero.org's `/projects`, never one of its own, so it shows the same proposals,
addresses and totals as the real CCS. Where this page says testnet, it describes the setup
before that.

## Where it differs

- **Testnet:** `testnet=1`, monerod on `28081`, wallet-rpc on `18182`; `MIN_CONFIRMATIONS=1`. Its
  own wallet and signed list ([subaddresses/testnet2](../subaddresses/testnet2/README.md)): every
  address the site shows is the testnet wallet's. A full wallet (its spend key too), so testnet
  donations can be sent from it.
- **The backend in Docker** (since 2026-10-29, [docker](docker.md)); since v0.2.35 (2026-10-30; now v0.2.36)
  without `compose.host.yml`, as [the handover, 1](handover.md#1-monerod-and-monero-wallet-rpc-the-backend)
  has it: the wallet syncs from node3's own monerod through its public restricted RPC,
  `host.docker.internal:18089` (unchanged for its other users; its flood rules count the wallet
  too); ccs-watch's Tor (`tor@default`) listens on `172.17.0.1:9050` as well as 127.0.0.1, for
  Docker's networks only (`SocksPolicy`, ufw), and starts after Docker; the bot by
  `host.docker.internal:8086`. `WALLET_PORT=18182`, `RPC_URL=http://wallet-rpc:18182/json_rpc`.
  `retire-wallet` now needs the wallet's RPC from the host ([docker](docker.md#running-it)). The host's
  `ccs-bash`, `ccs-wallet-rpc` and ccs-watch units are disabled, kept for going back. The
  compose runs from `/opt/ccs-bash` at the release's commit, its images by their attested IDs
  (`ccs config:check`: none failing).
- **The web server's side in Docker** ([the web server in Docker](docker.md#the-web-server-in-docker)):
  node2 is the web server and the backup machine both, so its compose (`/opt/ccs-bash-web`, at
  the release's commit, the gate's attested image) runs the backup receiver too
  (`COMPOSE_PROFILES=backup`), which production must not copy. Its host sshd takes no key of
  `ccs-data` or `ccs-backup` (`AuthorizedKeysFile none` for them).
- **A retired wallet, rehearsed** (2026-10-28, [retiring a wallet](handover.md#retiring-a-wallet)):
  the first testnet wallet ([subaddresses/testnet](../subaddresses/testnet/README.md), `fresh_test`)
  retired as `testnet` while still receiving, then a donation to one of its old addresses after
  the switch, recorded by `retire-wallet --again` as `testnet-2`: the same 319 totals across the
  switch, the late one added. Its wallet-rpc for `--again`: `systemd-run --unit
  ccs-old-wallet-rpc` on `127.0.0.1:18183` (its config in `/run/ccs-old-wallet/`, its login in
  `/root/ccs/pre-retire/old-rpc-login`; gone at a reboot: started again the same way). On the
  testnet a donation can't be faked from the wallet itself: a transfer to its own subaddress is an
  "out" only, which no record counts; send it from another wallet.
- **The proposals on gitlab.com** ([plowsof/ccs-proposals](https://gitlab.com/plowsof/ccs-proposals),
  since 2026-10-28; disroot's Forgejo before): `master` is monero-project/ccs-proposals as of
  2026-10-09, and the testnet runs its `testnet` branch (master, the tags of the commit below, and
  the testnet's own proposals, merge requests to `testnet`). ccs-bash's `REPOSITORY_URL` is
  `https://gitlab.com/api/v4/projects/88213536`, the checkout on `testnet`; the gate's
  `proposals.conf`: `PROPOSALS_GIT=https://gitlab.com/plowsof/ccs-proposals.git`,
  `PROPOSALS_BRANCH=testnet`, `LINK_HOSTS=repo.getmonero.org/monero-project/ccs-proposals`, where
  the older proposals' merge requests are. The backend's checkout had a commit of its own (tags),
  rebased on each pull: it is in `testnet` now. Moving it: [another forge](setup.md#proposals-on-another-forge).
  Its CI/CD configuration file is ccs-proposal-pre-parser's `gitlab_comment_workflow.yml`, by its
  raw URL at a commit (the API's `ci_config_path`): one comment on each merge request, edited in
  place, from n1oc (a project access token named so: Reporter, scope `api`, until 2027-10-27, in
  the masked variable `PRE_PARSER_TOKEN`): the check passed, or its errors; once merged, the links
  to the file and its editor; from Work in Progress on, its payouts, what remains and its tags,
  updated on each change to `testnet` (a protected branch). A new token: delete the old one's
  comments, then run a pipeline on `testnet` with `PRE_PARSER_REFRESH=1`.
- **The real CCS's totals:** the CCS1 and CCS2 wallets' donations, by proposal, as retired wallets
  (`STATE_DIR/retired/ccs1.csv` and `ccs2.csv`, [retiring a wallet](handover.md#retiring-a-wallet)):
  numbers only, no addresses, so the site's raised amounts look like the real CCS's.
- **The IRC bot** runs on the backend machine itself: the backend's alerts reach it as
  `host.docker.internal:8086`, the web server's over HTTPS through that machine's proxy (it
  listens on every address, its port open to all: its path is all that keeps others from posting). They go to `#montero-ccs-emojis`. So
  root on the backend can also silence the web server's alerts (a held-back page, no push); the
  CCS's bot belongs on a third machine.
- **ccs-watch fetches through Tor only** (no clearnet proxy): a web server that serves Tor's exits
  the right pages and everyone else others isn't seen.
- **A Forgejo Actions runner on the backend**, for every repository of its owner on disroot (the
  testnet proposals' pre-parser among them, while they were there): anyone opening a pull request
  there starts a job on the wallet's machine (master's script, in an unprivileged container with
  no Docker socket and no route to the wallet's RPC). A risk the testnet takes; the CCS's backend
  runs nothing but the CCS.

## The machines aren't separate

The backend is a shared host: other people's services open to the internet, more CI runners
(some running jobs on the host itself), and Coolify building ccs-front-hugo's branches in its
Docker, whose nightly cleanup has removed images in use (hence the stopped `-keep` container on
each image, [upgrading](handover.md#upgrading)). Its root has a key that logs in, with sudo, on
the other machine. The web server and the backup machine are one machine, which runs other
services too (since 2026-10-27, when the cloud provider disabled the first web server's
instance): monero nodes and other daemons open to the internet, run by an account with sudo, other
people's keys, ssh open to all. So on the testnet, root on the backend is root everywhere, a hole
in any of node2's services is root over the gate and every backup, and the two-machine
guarantees ([who can do what](handover.md#who-can-do-what)) don't hold there.

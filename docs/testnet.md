# The testnet

https://ccs.monerodevs.org runs this setup on Monero's testnet, so that each release and each step
of [the handover](handover.md) runs somewhere before ccs.getmonero.org. The set it runs: [the
releases](handover.md#the-releases). Nothing here is part of the setup: don't copy it.

## Where it differs

- **Testnet:** `testnet=1`, monerod on `28081`, wallet-rpc on `18182`; `MIN_CONFIRMATIONS=1`. Its
  own wallet and signed list ([subaddresses/testnet](../subaddresses/testnet/README.md)): every
  address the site shows is the testnet wallet's.
- **The proposals on Forgejo** (disroot): ccs-bash's `REPOSITORY_URL` is
  `https://git.disroot.org/api/v1/repos/plowsof/ccs-proposals`; the gate's `proposals.conf`:
  `PROPOSALS_GIT=https://git.disroot.org/plowsof/ccs-proposals.git`,
  `LINK_HOSTS=repo.getmonero.org/monero-project/ccs-proposals`, where the older proposals' merge
  requests are. The backend's checkout has a commit of its own (tags), rebased on each pull.
- **The real CCS's totals:** the CCS1 and CCS2 wallets' donations, by proposal, as retired wallets
  (`STATE_DIR/retired/ccs1.csv` and `ccs2.csv`, [retiring a wallet](handover.md#retiring-a-wallet)):
  numbers only, no addresses, so the site's raised amounts look like the real CCS's.
- **The IRC bot** runs on the backend machine itself: the backend's alerts reach it on 127.0.0.1,
  the web server's over HTTPS through that machine's proxy. They go to `#montero-ccs-emojis`.
- **A Forgejo Actions runner on the backend**, for every repository of its owner on disroot, the
  testnet proposals' pre-parser among them: anyone opening a pull request there starts a job on
  the wallet's machine (master's script, in an unprivileged container with no Docker socket and
  no route to the wallet's RPC). A risk the testnet takes; the CCS's backend runs nothing but the
  CCS.

## The machines aren't separate

The backend is a shared host: other people's services open to the internet, more CI runners
(some running jobs on the host itself), and Coolify building ccs-front-hugo's branches in its
Docker, whose nightly cleanup has removed images in use (hence the stopped `-keep` container on
each image, [upgrading](handover.md#upgrading)). Its root has a key that logs in, with sudo, on
the other machine. The web server and the backup machine are one machine, which runs other
services too (since 2026-10-27, when the cloud provider disabled the first web server's
instance). So on the testnet, root on the backend is root everywhere, and the two-machine
guarantees ([who can do what](handover.md#who-can-do-what)) don't hold there.

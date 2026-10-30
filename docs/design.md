# Recommended design

**No front-end framework on any live machine, and no application code on the public web
server.** Bash, awk and jq on a backend that accepts no connections turn the proposals and the
wallet into finished HTML; the web server only receives the files and serves them.

![Bash on the backend renders the whole site and pushes it; the web server only serves files](design.svg)

## Why not a live front end

| | A live Node front (the proposed new ccs-front) | This design |
|---|---|---|
| Code reachable from the internet | the app and its npm tree | nginx serving files |
| Supply chain on live machines | npm (today's ccs-front: Ruby gems) | bash, awk, jq, qrencode |
| Proposal Markdown rendered by | the framework, on the public server | a small awk renderer that escapes everything first, on the backend |
| A compromised web server | can change any page until noticed | can too, but every page is pushed again each run, and ccs-watch alerts IRC within minutes |

The donation addresses are what an attacker wants, and the web server shows them: keep it smallest.

## The parts

**The design** (offline, never live): ccs-front-hugo, the only place a framework (Hugo) runs. It
builds the site once per design change, with markers where content goes: "the original",
carried to the backend as a release zip whose sha256 is checked there.

**Backend** (no inbound connections; out only to the forge, monerod, the web server, the backup
machine and the IRC bot):

- **monero-wallet-rpc**, view-only, its own user, on 127.0.0.1 (in Docker: on a network only
  ccs-bash is on).
- **ccs-bash**: the JSON and the state, every 2 minutes or on a new tx. It reads the network (the
  forge), so nothing it writes is trusted further on. A proposal's total counts the live wallet
  and every retired one (recorded in the state, each deposit counted once); no total can go down from one run to
  the next unless allowed by hand ([retiring a wallet](handover.md#retiring-a-wallet)).
- **ccs-front-bash**: fills a fresh copy of the original each run (about 1.5 s for 316
  proposals): every proposal page, the stage lists, each donation box. Every donation address is
  checked against the wallet's signed list (below); a proposal whose address isn't on it is left
  off and the run counts as failed. It makes the QR codes itself, from checked addresses.
- **ccs-watch**, after each push and between pushes at random times: fetches the live donation
  pages, the files they use, ten other pages at random and `/projects`, as a visitor's browser
  would (one of three) and through Tor and a clearnet proxy, and alerts IRC if any differs from
  what was pushed. It catches what the gate can't: a taken-over web server that serves its own
  pages to everyone, or to whoever it can't tell from the watcher; not one that tells them apart
  (curl's TLS handshake can give it away), which is why the Verify page asks visitors to check
  ([details](two-machines.md#watching-the-web-server-the-backend-raises-the-alarm)).
- **Backups** to another machine (not the web server), whose account can only add copies:
  `proposals.csv` (which proposal has which subaddress; nothing can make it again) and each
  retired wallet's record (only wallets its admin listed; a later version may only rename
  proposals), every version (`assigned.tsv`, the heights below which a subaddress's deposits
  came before it was handed out, isn't: lost, those few count again); `deposits.csv`, a cache, as
  one copy that only grows, so a restored
  wallet that knows less is caught ([setup](setup.md#backing-up-the-state)). Root on the backup
  machine can still rewrite them all: restore the first retired version, and check a restored
  `proposals.csv` against the live site.
- **Pinned images:** ccs-bash and ccs-front-bash run in [StageX](https://stagex.tools) images
  ([details](image.md)), read-only, no capabilities, ccs-front-bash without network; in Docker,
  each step in its own container, as its own user ([docker](docker.md)). The wallet's image is
  getmonero.org's release binary on Debian, checked against its signed hashes, built on the
  backend and not attested (monero isn't in StageX).
- **Attested releases:** anyone can rebuild a release from its tag, byte for byte, and sign the
  result into [ccs-sigs](https://github.com/plowsof/ccs-sigs), as Feather Wallet does; a release is
  verified against those signatures before it is installed ([contrib/release](../contrib/release/README.md)).
- **The push:** `site/` to the web server, only the files whose contents changed (`rsync
  --checksum --delay-updates`: ccs-front-bash makes every file anew each run, so their times
  always differ).

**Web server:** the distribution's nginx (StageX has none, and builds for amd64 only) serving
`/var/lib/ccs-data`, and a write-only push account whose key runs only the gate
(`contrib/ccs-receive`): through the host's sshd, or in Docker through the gate image's own sshd
on its own port (StageX, attested with ccs-bash's release). The gate holds back any page that isn't the design's own, filled as
ccs-front-bash fills it (a proposal's text as the proposals repository has it), any file with an
address that isn't the wallet's (as text, link or QR code), and any other file that isn't the
design release's ([details](two-machines.md#the-gate-the-web-server-checks-every-page)). Nothing
else of the CCS runs there but the gate's heartbeat (an alert when pushes stop).

ccs-front-bash runs on the backend: whatever writes the addresses into pages can redirect
donations, so it belongs with ccs-bash, and pushing finished pages overwrites a page changed on
the web server on the next run.

## What one compromise can and can't do

The two machines watch each other, and each one's alarm reaches IRC without passing through the
other: the gate's goes from the web server to the bot, ccs-watch's from the backend. That holds
only with the bot on a third machine: a bot on the backend (the testnet's) lets the backend's root
drop the gate's alarms.

- **The web server taken over:** it can serve what it likes, but the backend's ccs-watch fetches
  the live pages and compares them with what was pushed. It can tell the watcher from visitors
  only by guessing (Tor and a clearnet proxy, three browsers' ways of asking, random times),
  which is why the Verify page asks visitors to check too. It can't change the state, the
  addresses or the backups.
- **The backend taken over:** it can push anything, but the gate lets through only the design's
  pages filled as ccs-front-bash fills them, the proposals' text as their repository has it, and
  addresses from the signed list, made offline by a Core Team member. It can stop pushing: the
  web server's heartbeat says so. It can't send a donation anywhere but the CCS wallet.

What the watching doesn't cover is one flaw that opens both at once:

- **The admins' own ssh**, the same sshd open to the internet on every machine: a flaw before its
  key check opens them all. [Admin access](admin-access.md) puts it behind a VPN or an allowlist.
- **The same packages on both sides** (StageX's ssh, rsync, curl, OpenSSL in both images):
  reachable from outside only through what each machine exposes, but also by each machine from
  the other: the web server answers the backend's push (rsync and ssh, as clients) and
  ccs-watch's fetches (curl). Each runs in a container of its own, as its own user, so a flaw
  there reaches that one stage, not the state or the wallet. But those two stages are the
  watching: a flaw in the push's client can rewrite what was pushed (the watch then finds it isn't
  the site the front made, whose sums are the front's own, and alerts), and a flaw in the watch's
  curl can silence the watch itself, whose alarm is then only the Verify page's visitors. Keep the
  pins current (`container/update-images.sh`).
- **One release for both sides:** the gate is in ccs-bash's repository and release, beside the
  backend it checks. Attesters should read the gate's changes as their own diff, not as part of
  the backend's.
- **One forge:** both machines read the proposals from it, so a forge taken over feeds them the
  same text; the signed list still holds the addresses.

## ccs-front-bash

**The original** is the built design, with markers where content goes and "parts" (a card, the
donation box, a milestone…) whose `{{slots}}` are filled; all HTML comes from it. It is never
modified: each run starts again from it, so a bad run can't build on a bad one.

```html
<!-- ccs:list fr -->…<!-- /ccs:list fr -->
<!-- ccs:donate -->…<!-- /ccs:donate -->
```

jq renders each fragment (every value HTML-escaped, links https only) and awk swaps it in. A
missing, unmatched or repeated marker fails the run; the last good site stays and is pushed again.

**Markdown:** a strict subset in awk. Everything is HTML-escaped first, so only tags the renderer
writes appear; raw HTML shows as text, links must be `https:`, images become links (nothing loads
from another site) except a proposal's own, in the repository's `images/<proposal>/`, which the
site serves from its copy. What the 268 proposals checked use:

| Used by | Feature |
|---|---|
| most | headings, paragraphs, lists, links, bare URLs, `*emphasis*` |
| tens | `**bold**`, numbered lists, `inline code` |
| a few | fenced code, `~~strike~~`, images (12), tables (5), quotes (5), reference links (5), footnotes (4) |
| 2 | raw HTML (shown as text) |

## The signed subaddress list

The wallet's subaddresses are listed once, in advance, and every address shown is checked
against it on both machines (the same five files on each: the list, `.asc` its signature,
`.key.asc` the key, `.pin` its sha256 and fingerprint, `.viewkey` for the Verify page); visitors
check the wallet itself:

| Where | Its job |
|---|---|
| the offline machine | made from a view-only wallet and signed by a Core Team member's own key (the one the Monero repository publishes); kept in ccs-bash's `subaddresses/<wallet>/` with `wallet.txt` (the wallet's address and view key), where others reproduce its sha256 |
| backend, `/etc/ccs-front/` | ccs-front-bash checks the list against its pin, then every donation address, and makes the QR codes from them: what ccs-bash's account writes can't change one |
| web server, `/etc/ccs-gate/` (installed by hand) | the gate checks every address on every pushed page, however written and in every QR code: a taken-over backend can't get a wrong one live |
| the Verify page | visitors check the address their wallet shows in a view-only copy of the CCS wallet, from its published address and view key: the defence left if the web server is taken over |

So a wrong address has to get past the backend, the web server, ccs-watch and anyone who looks
(each check, by function: [reviewing](reviewing.md#where-an-address-is-checked-against-the-signed-list)).
When the wallet nears index 15,000, a longer list is made and signed the same way; a new wallet
gets a list of its own, and the old one's addresses leave the site when it is retired.

## Setting it up

From ccs-back and Jekyll to this, step by step: [the handover](handover.md). The testnet CCS,
https://ccs.monerodevs.org, runs it ([testnet](testnet.md)).

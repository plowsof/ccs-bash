# Security review: what is protected, and against whom

For a reviewer: what an attacker wants, what each machine or key gets them, what stops it and
what notices. [Reviewing](reviewing.md) walks the code file by file; [the design](design.md) says
why it is built this way.

## What an attacker wants

| Asset | Why | Protected by |
|---|---|---|
| **The donation addresses shown** (text, `monero:` link, QR code) | a wrong one takes donations | the signed list, checked on both machines; ccs-watch; the Verify page |
| A proposal's text, milestones and payouts | changing what a reviewed proposal says or is paid for | the gate renders each from the proposals repository itself and compares |
| The totals raised | a proposal shown as funded when it isn't, or the reverse | from the wallet each run; never lower than the last run's (one run at a time, by hand) |
| `proposals.csv` (which proposal has which subaddress) | lost, donations can't be attributed | backups to a machine whose account can only add copies |

Not secret: the wallet's address and view key are public (anyone can see what it received), and
so is everything the site shows.

## Out of scope

- **The funds.** The CCS wallet's spend key is held by a Core Team member, outside this system:
  nothing here can spend, and nothing here can stop its holder from spending.
- monerod, the forge (GitLab or Forgejo) and its reviews, the visitor's device and wallet.

## Who can do what if compromised

| Taken | Can | Stopped by | Noticed by |
|---|---|---|---|
| The push key (`ccs-data`) | send files to the gate | the gate: a page that isn't the design's filled as ccs-front-bash fills it, an address not on the list (in any form, QR codes included), a changed proposal text, image or design file is held back | the gate's own IRC alert |
| ccs-bash's account (`ccs`) on the backend, or the forge's data it reads | change the JSON and the state | ccs-front-bash checks every address against the list in root-owned `/etc/ccs-front/`; then the gate | ccs-front-bash fails the run (three in a row: IRC); the gate |
| Root on the backend | push anything; stop ccs-watch | the gate, with its own copy of the list, design and proposals | the gate's alerts; the heartbeat if it goes silent |
| Root on the web server | serve anything: the gate is bypassed | nothing on that machine | ccs-watch (via Tor and a clearnet proxy) within minutes; visitors using the Verify page |
| Root on both machines | everything the site shows | **nothing technical** | only visitors who check an address in a view-only wallet |
| The backup machine's account | add copies | can't read, change or delete one | |
| A release (its source or build) | anything it runs | reproducible builds, attested in ccs-sigs by people who rebuilt them, verified before installing | a differing attestation |

Hence: **a different SSH key, ideally a different person, for each machine's root**
([handover](handover.md#who-can-do-what)).

## Known limits

- **The list signer and the wallet holder.** Whoever signs the subaddress list could sign one for
  another wallet. What limits that is public record, not code: the wallet's address and view key
  are published, so anyone can rebuild the list and compare its sha256.
- **Visitors who don't check.** The Verify page is the last defence against a taken-over web
  server, and it only helps those who use it.
- **The window.** A taken-over web server can serve a wrong address until ccs-watch notices (one
  run, about 2 minutes) and someone acts.
- **Availability.** A forge that is down leaves the last proposals and ideas; a web server that is
  down shows nothing. Neither can show a wrong address.
- **monero-wallet-rpc** decides the totals; a lying one can raise them (never-lower stops only a
  drop).

## Where to look

- The gate, `contrib/ccs-receive`: [what it checks](two-machines.md#the-gate-the-web-server-checks-every-page);
  `tests/gate.sh` lists the ways around it tried so far (address split by markup, bidi, look-alike
  characters, invisible images, QR codes…). A new one that gets a wrong address live is the most
  valuable finding.
- The markdown renderer, `lib/markdown.awk` (ccs-front-bash): everything escaped first, links
  `https:` only.
- ccs-front-bash's address check against the list and its pin.
- ccs-watch, `contrib/ccs-watch`: that what is served is what was pushed.

Report anything that could get a wrong address live privately to the maintainers, not as a
public issue.

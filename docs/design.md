# Recommended design

A proposal for how the CCS should run: **no Jekyll, Astro or other front-end framework on any
live machine, and no application code on the public web server.** Bash, awk and jq on a backend machine that
accepts no connections turn the proposals and the wallet into finished HTML; the web server
only receives the files and serves them.

![Bash on the backend renders the whole site and pushes it; the web server only serves files](design.svg)

## Why not a live front end

The proposed new ccs-front is a Node application served live. Compared with static files:

| | Live Node front | This design |
|---|---|---|
| Code reachable from the internet | the app and its npm dependency tree | nginx serving files |
| Supply chain on live machines | npm (and for today's ccs-front, Ruby gems) | bash, awk, jq, qrencode |
| Proposal Markdown rendered by | the framework, on the public server | a small awk renderer that escapes everything first, on the backend |
| A compromised web server | can change any page until noticed | can too, but every page is pushed again each run |
| JavaScript needed by visitors | usually | no; works over Tor with JS off |

The donation addresses are what an attacker wants, and the web server is where they are shown,
so that is the machine to keep smallest.

## The parts

**Front-end build** (offline, never live): ccs-front-hugo, the only place a framework (Hugo)
runs. It builds the site once per design change, with markers where content goes; the built
site is carried to the backend (a signed git commit, or a copy whose sha256 is checked there)
and is "the original". Nothing here runs while the CCS does.

**Backend** (no inbound connections; only outgoing to GitLab and monerod):

- **monero-wallet-rpc**, view-only, its own user, on 127.0.0.1.
- **ccs-bash**: data only, the JSON and the state file, every 2 minutes or on a new tx.
- **ccs-front-bash**: every run, fills a fresh copy of the original from the proposals' `.md`
  files and ccs-bash's JSON: every proposal page (its Markdown as HTML, its milestones and
  payouts), the Ideas, Funding Required, Work in Progress and Completed lists, and each
  donation box (raised, goal, percentage, contributors, pending, address, QR code). All of it,
  every run: about 1.5 seconds for 316 proposals.
- **Push:** the complete `site/` to the web server, as in [two machines](two-machines.md) but
  with HTML instead of JSON (`rsync --checksum --delay-updates`).

**Web server:** nginx serving `/var/lib/ccs-data`, and the write-only `ccs-data` account
(`rrsync -wo -no-del -munge`). Nothing else: no checkout, no cron, no Jekyll, Node, Ruby or PHP.

ccs-front-bash runs on the backend, not on its own machine or the web server: whatever writes
the addresses into the pages can redirect donations, so it belongs with ccs-bash, and pushing
finished pages means a page changed on the web server is overwritten on the next run.

## ccs-front-bash

**The original:** ccs-front-hugo's built site, with markers where content goes, and "parts"
(the card, the donation box, a milestone…) whose `{{slots}}` ccs-front-bash fills: every piece
of HTML comes from the original. It is never modified: each run starts again from it,
so the output depends only on the original and today's data, a bad run can't build on a bad
one, and a new proposal's page is a copy of the original's proposal page.

```html
<!-- ccs:list fr -->…<!-- /ccs:list fr -->
<!-- ccs:donate -->…<!-- /ccs:donate -->
```

jq renders each fragment from the JSON (every value HTML-escaped, links https-only, as
`lib/site.jq` does now) and awk swaps it in. A missing, unmatched or repeated marker fails the
run, and nothing is pushed. Output goes to a new directory, so a failed run leaves the last good
site in place.

**QR codes:** made here, next to the address they encode, and inlined into the page. ccs-bash
makes them today (`donate-qr-code`) only because ccs-front expects them in the JSON, as with
ccs-back; once ccs-front-bash replaces ccs-front, ccs-bash stops.

**Markdown:** a strict subset in awk, in the spirit of `lib/frontmatter.awk`. Safe by
construction: all text is HTML-escaped first, and only tags the renderer writes itself ever
appear. Raw HTML in a proposal is shown as text, link URLs must be `https:`, images become links
(nothing on a page loads from another site), and
anything not understood stays plain text. In the 268 proposals checked:

| Used by | Feature |
|---|---|
| most | headings, paragraphs, lists, links, bare URLs, `*emphasis*` |
| tens | `**bold**`, numbered lists, `inline code` |
| a few | fenced code, `~~strike~~`, images (12), tables (5), quotes (5), reference links (5), footnotes (4) |
| 2 | raw HTML (shown as text) |

Before switching over, every proposal's page is compared with today's site once, on a
development machine.

## Getting there

1. **Before:** ccs-bash makes JSON; Jekyll builds the site from it ([two machines](two-machines.md)).
2. **ccs-front-hugo and ccs-front-bash:** done, and running the testnet CCS since 2026-10-23
   (nginx serving ccs-front-bash's site, under the CSP above). Left: pushing the site to a
   separate web server, as in [two machines](two-machines.md).
3. **ccs-bash data only:** drop `donate-qr-code` from its JSON, once nothing reads it.

## Open questions

- **The original:** who signs its commits.
- **Watching the site:** with every page coming from the backend, a checker can compare the
  live site with what was pushed, byte for byte (the README's to-do).

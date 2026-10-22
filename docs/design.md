# Recommended design

A proposal for how the CCS should run: **no Jekyll or front-end framework on any machine, and
no application code on the public web server.** Bash, awk and jq on a backend machine that
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

**Backend** (no inbound connections; only outgoing to GitLab and monerod):

- **monero-wallet-rpc**, view-only, its own user, on 127.0.0.1.
- **ccs-bash**: data only, the JSON and the state file, every 2 minutes or on a new tx.
- **ccs-front-bash**: everything a visitor sees, from `templates/`, the proposals' `.md`
  files and ccs-bash's JSON:
  - proposal pages: Markdown → HTML, re-rendered only when a `.md` file changes;
  - every run: the Ideas, Funding Required, Work in Progress and Completed lists, and each
    proposal's donation box (raised, goal, percentage, contributors, pending, address, QR code).
- **Push:** the complete `site/` to the web server, as in [two machines](two-machines.md) but
  with HTML instead of JSON (`rsync --checksum --delay-updates`).

**Web server:** nginx serving `/var/lib/ccs-data`, and the write-only `ccs-data` account
(`rrsync -wo -no-del -munge`). Nothing else: no checkout, no cron, no Jekyll, Node, Ruby or PHP.

ccs-front-bash runs on the backend, not on its own machine or the web server: whatever writes
the addresses into the pages can redirect donations, so it belongs with ccs-bash, and pushing
finished pages means a page changed on the web server is overwritten on the next run.

## ccs-front-bash

**Templates:** plain HTML files with markers where content goes, made once by hand from
ccs-front's layouts and kept in git:

```html
<!-- ccs:fr-list -->…<!-- /ccs:fr-list -->
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
appear. Raw HTML in a proposal is shown as text, link and image URLs must be `https:`, and
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

1. **Today:** ccs-bash pushes JSON; the web server runs Jekyll ([two machines](two-machines.md)).
2. **ccs-front-bash:** templates, the lists and donation boxes, QR codes, and the Markdown
   renderer; push the whole site. The web server becomes nginx only and Jekyll is gone.
3. **ccs-bash data only:** drop `donate-qr-code` from its JSON.

## Open questions

- **Images:** 12 proposals embed images from other sites, which tells those sites who is
  reading. Show them as links instead, or copy them in when a proposal is merged?
- **Templates:** who keeps them in step with ccs-front's design.
- **Watching the site:** with every page coming from the backend, a checker can compare the
  live site with what was pushed, byte for byte (the README's to-do).

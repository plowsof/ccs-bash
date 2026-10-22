# Recommended design

A proposal for how the CCS should run: **the public web server runs no application code**.
It only receives finished files and serves them. Everything that computes, renders or talks to
the wallet runs on a backend machine that accepts no connections.

![The backend builds the whole static site and pushes it; the web server only serves files](design.svg)

## Why not a live front end

The proposed new ccs-front is a Node application served live. Compared with static files:

| | Live Node front | This design |
|---|---|---|
| Code reachable from the internet | the app and its npm dependency tree | nginx serving files |
| Supply chain on the public server | every `npm install` | none (no build there) |
| Proposal Markdown (from merged MRs) rendered | on the public server | on the backend, no network |
| A compromised web server | can change any page until noticed | can too, but every page is pushed again each run |
| JavaScript needed by visitors | usually | no; works over Tor with JS off |

The donation addresses are what an attacker wants, and the web server is where they are shown,
so that is the machine to keep smallest.

## The parts

**Backend** (no inbound connections; only outgoing to GitLab and monerod):

- **monero-wallet-rpc**, view-only, its own user, on 127.0.0.1.
- **ccs-bash**: the JSON and the state file, every 2 minutes or on a new tx (as today).
- **Site build, slow path:** ccs-front built in a pinned container image with no network, only
  when the proposals repo or ccs-front changes (a merge, a front-end release). This is the only
  place proposal Markdown is rendered.
- **ccs-front-bash, fast path:** every run, copy the last build and fill in only what changes
  between merges: the Ideas, Funding Required, Work in Progress and Completed lists, and each
  proposal's donation box (raised, goal, percentage, contributors, pending, address, QR code).
- **Push:** the complete `site/` to the web server, as in [two machines](two-machines.md) but
  with HTML instead of JSON (`rsync --checksum --delay-updates`).

**Web server:** nginx serving `/var/lib/ccs-data`, and the write-only `ccs-data` account
(`rrsync -wo -no-del -munge`). No ccs-front checkout, no proposals pull, no cron, no Jekyll,
Ruby, Node or PHP.

## ccs-front-bash

The templates mark each region that changes between builds:

```html
<!-- ccs:fr-list -->…<!-- /ccs:fr-list -->
<!-- ccs:donate fund-me.md -->…<!-- /ccs:donate -->
```

Each run, for each marked region, jq renders the fragment from ccs-bash's JSON (every value
HTML-escaped with `@html`, links https-only, as `lib/site.jq` does now) and awk swaps it in. The
run fails, and nothing is pushed, if a marker is missing, unmatched or repeated, or a page names a
proposal the JSON doesn't have. Output goes to a new directory, so a failed run leaves the last
good site in place.

The markers are a small patch to ccs-front's layouts (like `contrib/ccs-front-local-url.patch`).
Any front end that can export static HTML with these markers works the same way, including a new
one written with npm, as long as it is **built** on the backend and never **served** by Node.

## Getting there

1. **Today:** ccs-bash on the backend pushes JSON; the web server runs Jekyll
   ([two machines](two-machines.md)).
2. **Build on the backend:** run the Jekyll build there in a pinned image and push the whole
   site every run. The web server becomes nginx only.
3. **ccs-front-bash:** add the markers and the fast path, so Jekyll only runs on a merge and the
   2-minute path is bash and jq.

Each step works on its own; step 2 alone removes everything but nginx from the web server.

## Open questions

- **The Jekyll image:** Ruby and the gems pinned and built from source (StageX, if it packages
  them) or at least pinned by checksum, run with `--network none`.
- **Markers in ccs-front:** upstream, or a patch kept here.
- **Watching the site:** with every page coming from the backend, a checker can compare the
  live site with what was pushed, byte for byte (the README's to-do).

# Two machines: the backend pushes, the web server only receives

The backend takes no incoming connections; after each run it pushes the site to the web server,
whose push key runs only the gate: it checks every file before it goes live, and Caddy serves what
passed. The gate and its heartbeat run from the gate's attested image, with their own sshd on
port 2223, and Caddy and Tor serve the site and its onion ([the web server in Docker](docker.md#the-web-server-in-docker)).

**The push account:**

```
install -d -m 755 /var/empty                              # its home: root's and empty (bash, git and curl read config from a home)
useradd --system --no-create-home --home-dir /var/empty --shell /bin/sh ccs-data   # no password; only the forced command runs (an existing one: usermod -d /var/empty ccs-data)
install -d -o ccs-data -m 755 /var/lib/ccs-data           # ideally its own small filesystem or a quota
install -d -m 755 /etc/ssh/authorized_keys                # root-owned, outside the account's home
# /etc/ssh/authorized_keys/ccs-data (root, 644):
from="<backend IP>",command="/usr/local/bin/ccs-receive",restrict ssh-ed25519 AAAA... ccs-bash
```

The push is a tar of the files that changed (the backend's [`contrib/ccs-push`](../contrib/ccs-push),
over this key, asking for `receive`), read by the gate's own Go code (`ccs-check receive`), never
by rsync or any other C program, into its staging folder, so:

| If the key is stolen, this stops | |
|---|---|
| `restrict` | shells, forwarding, a terminal |
| `command=` the gate, which takes `receive` only | any other command (a shell, scp, rsync, reading back) |
| `ccs-check receive`: plain files, at clean paths under the folder (folders only as a file needs them, and none left live by a held-back file) | an empty folder standing where a page comes later; writing outside it (`..`, an absolute path), links of either kind (a `projects.json` link to any file would get the web server to publish it), devices, a name twice, a file under a page: any of them refuses the whole push |
| no delete in the push at all | deleting |
| its limits: 512 MB a push, 64 MB a file, 100,000 files, 5 minutes | filling the disk, holding the gate |
| `from=` | use from another machine |
| key file root-owned, outside its home | loosening the key line, adding a key |
| own filesystem / quota | filling the disk |

**The site: Caddy and Tor**, the web server compose's `www` and `tor`, from the gate's image
(StageX's Caddy; Tor built from its signed source), each read-only, as its own user, without
capabilities. Their config is in the image, the same on every machine:
[`Caddyfile`](../contrib/docker/web/Caddyfile) and [`torrc`](../contrib/docker/web/torrc).
Caddy serves `/var/lib/ccs-data` (read-only), the files the gate let through, over HTTPS at
`CCS_SITE_HOST`; it gets and renews its certificate itself (Let's Encrypt, ACME, as
`CCS_ACME_EMAIL`), so no certbot. It speaks HTTP/1.1 only, ignores `Range`, caps a request's
headers at 16 KB and drops slow clients: a site of small static files loses nothing, and the
parts of Go's HTTP server with the most known denial-of-service bugs are never reached. The
`vulncheck` workflow checks the pinned Caddy's binary weekly against Go's vulnerability database:
each one found is listed in [`container/caddy-vulns-accepted`](../container/caddy-vulns-accepted)
with why it doesn't reach the site (turned off here, or code this config never runs), and any
other fails it; the `upstream` workflow says when StageX has a newer Caddy (or Tor a newer
release) to pin. The security headers, on every
answer, the 404 page too (beta.getmonero.org's, with a stricter CSP; A+ on securityheaders.com),
and no `Server` header:

```
Content-Security-Policy: default-src 'none'; style-src 'self'; img-src 'self'; font-src 'self'; frame-ancestors 'none'; base-uri 'self'; form-action 'none'
Strict-Transport-Security: max-age=31536000; includeSubDomains          (HTTPS only)
X-Content-Type-Options: nosniff
X-Frame-Options: DENY
Referrer-Policy: no-referrer
Permissions-Policy: accelerometer=(), ambient-light-sensor=(), autoplay=(), battery=(), camera=(), clipboard-read=(), clipboard-write=(), display-capture=(), document-domain=(), encrypted-media=(), fullscreen=(), geolocation=(), gyroscope=(), hid=(), idle-detection=(), interest-cohort=(), magnetometer=(), microphone=(), midi=(), payment=(), picture-in-picture=(), publickey-credentials-get=(), screen-wake-lock=(), serial=(), sync-xhr=(), usb=(), xr-spatial-tracking=()
X-XSS-Protection: 0
Onion-Location: http://<the onion>/<the page>                          (HTTPS only)
```

| Header | Stops |
|---|---|
| `Content-Security-Policy` | anything loading from another site, any script, inline styles; `frame-ancestors 'none'`: another site showing a page in a frame with its own address drawn over the donation box (`default-src` doesn't cover it); `base-uri 'self'`: for the 404 page's `<base href="/">` |
| `Strict-Transport-Security` | plain HTTP once a browser has seen HTTPS, so nobody on the way can strip it (ignored over HTTP, so harmless on port 80). No `preload`: that is for a whole domain |
| `X-Content-Type-Options` | a file run as a script or stylesheet when the server says it is something else (not images: a browser shows any image bytes, hence the gate's rule that pages start as text) |
| `X-Frame-Options` | framing, for browsers older than `frame-ancestors` |
| `Referrer-Policy` | other sites learning which page a visitor came from |
| `Permissions-Policy` | every browser feature the site doesn't use (camera, payment, clipboard…) |
| `X-XSS-Protection: 0` | old browsers' XSS filters, which could be used to blank parts of a page; the CSP is the protection |

Pages go out as `text/html; charset=utf-8`, which overrides any `<meta charset>`, so a page can't
switch to an encoding where bytes the gate read as text show as something else. A missing page or
a folder without one answers the site's 404 page (a 403 would say it exists); ccs-watch reads any
answer but 200 as the page not served. Text (HTML, CSS, XML, JSON) is gzipped, images not.

**Caching:** stylesheets, icons, fonts and the home page's pictures are named by their hash
(`style.<sha256>.css`), so browsers keep them for good (`immutable`, a year: no layout shift, even
on Tor); the General Fund's QR code (on every page, never changing) a day; everything else,
`no-cache`, checked before reuse; `/projects` (projects.json, as JSON) revalidated each time.

**The theme** (Light, Dark, System), kept in the address, without cookies or JavaScript: `/dark/…`
and `/light/…` are the same files with another `assets/theme.css` (`theme-dark.css`,
`theme-light.css`), and the button's `?theme=light|dark|system` redirects (302) to the page under
that prefix (links are relative, so it stays). These are the very files the gate checked and
ccs-watch compares. The redirect never names an address starting `//` or `/\`, which a browser
takes as another site's: such a path redirects to the home page.

**The onion** (optional): the same site for Tor Browser users, without an exit node. The
compose's `tor` publishes it; Caddy serves it the very files and headers the clearnet site has,
through a socket in `/var/lib/ccs-www/onion`, which only the two mount: no port, so nothing else on
the machine reaches the onion's side. A single-hop service: the site is public and its address
known, so the server's own anonymity buys nothing, and fewer hops make it quicker. The clearnet
site says so (`Onion-Location`, which Tor Browser turns into ".onion available"), and so does the
footer: the address in `/etc/ccs-gate/onion` (root, 644), the same as the web server's `.env`
`CCS_ONION` and the backend compose's `CCS_ONION`, which ccs-front-bash writes in every page's
footer. The gate takes the footer's onion line only with the address in its own file: a backend
can't point visitors at another onion. The onion's key, `/var/lib/ccs-tor/ccs/hs_ed25519_secret_key`,
is the onion's identity, as the TLS key is the clearnet site's: back it up as root, show it no one.

**Setting them up**, as root: their users and folders, then the compose ([the web server in
Docker](docker.md#the-web-server-in-docker)):

```
for u in ccs-www ccs-tor; do useradd --system --no-create-home --shell /usr/sbin/nologin $u; done
install -d -o ccs-www -m 755 /var/lib/ccs-www /var/lib/ccs-www/onion /var/lib/ccs-www/sites
install -d -o ccs-www -m 700 /var/lib/ccs-www/data          # Caddy's certificates and ACME account
install -d -o ccs-tor -m 700 /var/lib/ccs-tor               # Tor's state; ccs/: the onion's keys (made at its first start)
```

In `.env`: `CCS_WWW_UID` and `CCS_TOR_UID` (`id -u ccs-www`:`id -g ccs-www`...), `CCS_SITE_HOST`
(the site's name, its DNS A and AAAA records this machine's), `CCS_ONION` (after the first start:
`/var/lib/ccs-tor/ccs/hostname`) and `CCS_ACME_EMAIL`. Ports 80 and 443 open to everyone. A site
of the machine's own beside the CCS (another host's ACME challenges, say): a file
`/var/lib/ccs-www/sites/<name>.caddy`, which the Caddyfile imports.

**The backend's key**, the push stage's, and the gate's own host key on its port, from the web
server's `/etc/ccs-gate/ssh/ssh_host_ed25519_key.pub` (not accepted on first connect):

```
install -d -o ccs-push -m 700 /etc/ccs/push
runuser -u ccs-push -- ssh-keygen -t ed25519 -N '' -f /etc/ccs/push/id_ed25519
echo "[<web server>]:2223 ssh-ed25519 AAAA..." > /etc/ccs/push/known_hosts
```

The push (a tar of the files that changed since what the gate last took, `contrib/ccs-push`) goes
to `CCS_PUSH_PORT` (2223) of the compose's `.env`. The web server needs 2223 open to the backend only (the backup machine: 2224)
and 80/443 to everyone, in its firewall *and* a cloud provider's (an Oracle security list, an AWS
security group). The admins' own ssh: [admin access](admin-access.md).

`tests/gate.sh` sends each of those as a tar from the backend's key (a symlink, a hard link, a
device, `..`, an absolute path, a name twice, a file under a page, a backslash, no tar at all):
each refuses the whole push, nothing live changes, nothing is written outside; `tests/web.sh`
tries other commands, forwarding and another machine; `contrib/ccs-check/build.sh test` and
`fuzz` the receiver itself. A taken-over backend can still push false pages: the gate is for that.

## The gate: the web server checks every page

`contrib/ccs-receive`, the push key's forced command. It doesn't guess how a browser shows
what it is sent; it knows what a page may be. Each push, one at a time, it

1. makes a staging folder a copy of the live site (`ccs-check copy`), and receives the push into
   it (`ccs-check receive`: a tar of plain files, as above). What it checks below are the
   files the push changed, and the ones it held back last time (their last good copy is live, so
   the same file sent again fails again): the live site holds only what passed, and a live one that no
   longer passes for an address goes (step 5). Every page and JSON file is checked again
   when what they were checked against changes (the list or its pin, `allowed`, the design,
   `markdown.awk`, `proposals.conf`, the proposals commit fetched, `ccs-receive` itself or
   `ccs-check`), and once a day whatever happens. Its log says how many: `checking 3 of 1022 pages and JSON files`;
2. checks **every page against the design**: the design's release zip, unpacked here, has every
   page and every part ccs-front-bash fills them with (ccs-front-hugo's README, "What
   ccs-front-bash fills in"). A page must be one of the design's own, byte for byte outside its
   `<!-- ccs:… -->` regions, each region filled with the design's parts and each `{{slot}}` with a
   value of its kind:
   - a number, an amount or a date as ccs-bash writes them;
   - a name, author or tag: escaped text, 1000 characters at most, no bidi controls (they can
     reorder an address's halves), and no run of 90 characters each base58 or not ASCII: no
     address, padded, split by invisible characters or drawn with look-alikes. ccs-bash shortens
     idea titles by the same rule;
   - a link to a proposal: the site's own page, or a merge request of the proposals repository
     itself (`proposals.conf`'s address, host and path, and `LINK_HOSTS`; `/-/merge_requests/N`,
     `/merge_requests/N` or `/pulls/N`): not another repository on its forge, which anyone can
     make, and no `..` step, `%` or backslash to leave it by. Any merge request number, though:
     anyone can open one there, so a taken-over backend could link a proposal's "Comments and
     updates" to theirs (the forge's page, saying whatever they wrote; not an address on the site);
   - a proposal's text, milestones and payouts: exactly what `markdown.awk` (installed here)
     makes of its file in the **proposals repository**, which the gate fetches itself each push
     (its last two commits, for a merge landing mid-push; the last fetch if it can't). A backend
     can't change what a reviewed proposal says, or what it is paid for;
   - the donation box: **one address of the signed list** (not `allowed`'s: those are no
     proposal's), the same in its text and `monero:` link, its QR code that address's file,
     `qr/<address>.png` (step 4); and **its proposal's**: the one the live site's `projects.json`
     has for it (a push can't give a proposal another address, nor one another proposal has, while
     the proposal is in the repository's newest commit: a renamed one's goes with it); for a
     proposal new to the site, the one the push's `projects.json` gives it, which no other
     proposal has;
   - `projects.json` (the `/projects` API: Feather's CCS tab shows it, its Donate button fills in
     the address) is checked here too: each entry exactly site.jq's of its proposal's front matter
     (its name, author, date, stage, goal and link; any number only for contributions, raised and
     percentage), every key once and no other, an address of the signed list on one proposal only,
     and the one the live site has for it;
   - `site-data.json` (what the web server is to build the site from itself, the design's
     step 6; for now only checked): what only the backend knows, each proposal's subaddress
     *index* (the signed list's line, never 0, one proposal's only, the live site's address for
     it), merge request, dates and funds as ccs-bash writes them, and the ideas, their names and
     authors plain text, their links the repository's merge requests; every key once, no other.

   A page not checked in time (5 minutes) or over 2 MB is held back: what isn't known good
   doesn't go live;
3. checks **every address** (95 or 106 base58 characters) in pages and JSON against the signed
   list and `allowed`, as written (tags and attributes too, entities decoded, a non-ASCII
   character read both as nothing and as a space; one in groups split by up to three spaces or
   punctuation, `4A9b - xZq3`, `4A9b/xZq3`, or split between two elements a browser lays side by
   side, two tag labels, where its checksum says it is one), the JSON as JSON
   too, its strings read the same way. One pass, 2 minutes at most for all; a file that needs more
   than 3000 checksums or 20 s is held back alone ("too many runs that could be addresses"), not
   every file with it. No `data:` image at all (the site's QR codes are files, step 4). Pages
   and JSON must start with `<`, `[` or `{` (a browser shows `<img src="x.html">` by its bytes);
4. checks every other file the push changes: the design's, byte for byte (`design.sha256`: a
   stylesheet can hide an address, an image be a QR code); a proposal's image the proposals
   repository has, byte for byte at that path (never read: the repository's review vouches for
   what it shows, [the web server](web-server.md#what-it-guarantees-and-what-not));
   a donation box's QR code, `qr/<address>.png`: the signed list's own file of that address, byte
   for byte (its sum in `subaddresses.txt.qr.sha256`, which the `.pin`'s `qr` line pins; made with
   the list, ccs-front-bash's `tools/make-qr.sh`): the gate never makes or reads one;
   `projects.json`; `feed.xml`, line for line as ccs-front-bash writes it (its items plain text,
   each a link to one of this site's proposal pages under `SITE_URL`, 100 at most, and no address
   at all, however written); or the list's files as installed here. Each a plain file where the live site
   has one (a symlink or a folder in a page's place would take the page away);
5. copies staging into the live site, except a file that fails, which keeps its last good copy:
   one bad page doesn't stop the rest. The push then exits 7 (a refused one: 1); which file and
   why: `journalctl -t ccs-gate` (and `/var/log/ccs-gate.log` if created), and IRC. The one
   exception: a proposal page the push didn't send, whose proposal is in neither commit just
   fetched (not the last fetch), and with nothing else wrong, is a proposal taken out of the
   repository (its `.md` in neither commit's tree). The push can't delete, so the gate takes it,
   and its `images/<name>/`, off the live site, and the push is good; but never more than 3 at
   once (`CCS_GATE_REMOVE`): more (a branch emptied or rewritten, a forge answering wrong) stay
   held back, and IRC is told. And a live file the push didn't send that no longer passes for an
   address (the list, `allowed` or the gate changed under it: an address that isn't the wallet's
   nor allowed, a donation box's not in the list) would stay live if held back: it goes off the
   site, into the gate's `quarantine/` (its state folder), and IRC is told; the backend's next
   good copy goes live. At most 3 a push (`CCS_GATE_TAKEDOWN`): more (a wrong list or `allowed`)
   stay, and IRC is told;
6. refuses the whole push without its pinned list (or with one of no addresses) and QR codes' sums, `design.sha256`, the design,
   `markdown.awk`, `proposals.conf`, `ccs-check` or `git`, a design release (`design/vX.Y.Z/`), or
   for a file name with a control character in it.

With `/etc/ccs-gate/alert.conf` it tells IRC itself (once an hour per address or file, three a
push, a foreign address first, also when the backend hangs up mid-check): the alarm that still
sounds when the backend is the one lying. Every line it sends, and what to do:
[troubleshooting, What IRC says](troubleshooting.md#what-irc-says).

Set it up once, as root (in Docker, then [its own steps](docker.md#setting-it-up-1)):

```
install -d -o ccs-data -m 755 /var/lib/ccs-staging
install -d -m 755 /etc/ccs-gate /etc/ccs-gate/design
install -d -o ccs-data -m 755 /var/lib/ccs-gate                      # one push at a time, the last push (the heartbeat), when it last alerted, the proposals fetched
install -m 640 -g ccs-data /dev/null /etc/ccs-gate/alert.conf        # optional: the bot (as ccs-watch's, plain text POST)
printf 'ALERT_URL=http://<bot>:8086/<path>\nSITE_URL=https://<site>\n' > /etc/ccs-gate/alert.conf
# (SITE_URL: also the feed's address; feed.xml passes only with links under it, the backend's CCS_SITE_URL)
# the signed list, its pin, signature and key (ccs-front-bash, setup step 5); its view key file too, if the backend has one
install -m 644 subaddresses.txt subaddresses.txt.pin subaddresses.txt.asc subaddresses.txt.key.asc subaddresses.txt.viewkey subaddresses.txt.qr.sha256 /etc/ccs-gate/
cat > /etc/ccs-gate/allowed <<'LIST'                                # other addresses allowed on the site, one a line
888tNkZrPN6JsEgekjMnABU4TBzc2Dt29EPAvkRxbANsAnjyPbb3iQ1YBRk1UXcdRsiKc9dhwMVgN5S9cQUiyoogDavup3H  # the General Fund
LIST
# the proposals repository the backend reads (its checkout's origin), and its branch; LINK_HOSTS:
# other places a proposal's link may go to, as host/path of a repository (an older forge its merge
# requests were on: repo.getmonero.org/monero-project/ccs-proposals). A host alone allows its
# every page, anyone's repository there too
printf 'PROPOSALS_GIT=https://repo.getmonero.org/monero-project/ccs-proposals.git\nPROPOSALS_BRANCH=master\n' > /etc/ccs-gate/proposals.conf
# the markdown.awk of the ccs-front-bash release the backend runs (its lib/markdown.awk)
install -m 644 <ccs-front-bash checkout at the attested commit>/lib/markdown.awk /etc/ccs-gate/markdown.awk
```

The list's files: as [the signed list](signed-list.md) says, checked for this machine too (a
taken-over backend would bring both a list and the sums it is compared with), the QR codes' sums
here but not their images.

**The design**, the release zip the backend runs, unpacked, and the sums of every file but the pages:

```
v=v0.1.29                                                            # the handover's releases table
sha256sum ccs-front-hugo-$v.zip                                      # the attested one
unzip -q ccs-front-hugo-$v.zip -d /etc/ccs-gate/design/$v
(cd /etc/ccs-gate/design/$v && find . -type f ! -name '*.html' -exec sha256sum {} +) > /etc/ccs-gate/design.sha256
```

Each design in `design/` named as its release (`v0.1.25`): the gate takes no other folder there
(a build of the design's left beside them is no design). A new design: unpack it beside the old one and **add** (`>>`) its lines to `design.sha256` before
the backend switches; the old can go once the new is live. A changed `markdown.awk`: install it
beside the old as `markdown-<release>.awk` first. Empty `/var/lib/ccs-data` before the first push
if anything is in it (the gate trusts what is live).

A proposal quoting another address doesn't update until that address is in `allowed` (the
refusal names it; on the testnet, two). A new list: its files, the same way.

`tests/gate.sh` builds this in containers (with `GATE_IMAGE`, from the gate's image) and pushes
each way around it, each case named in its output:

- **held back:** an address split, disguised (entities, invisible or look-alike characters, bidi)
  or in a QR code of another address; a QR code that isn't the list's file of the box's address,
  or a `data:` image; a page or text that isn't the design's or the repository's;
  a link out of the repository; a stylesheet, image or list that isn't the installed one;
- **refused, every push:** no design or `markdown.awk`, a list that isn't the pinned one;
  deleting, and anything outside the folder;
- **checked again:** only what a push changed; a held-back file sent again unchanged; every page
  after a change to what it is checked against, or a day after the last full check;
- **through:** a good push after a held-back one; the repository down; two pushes at once;
- **alerts:** a check that stops holds back every page; a backend that hangs up mid-check.

**What it can't see:** what only the backend knows: a total, count or percentage that is wrong but
a number; an idea that is no merge request (still escaped text linking to the repository); one of
the address a proposal new to the site is first given (one of the list's that no other proposal
has: from then on it is that proposal's); the dates only the backend keeps (when a proposal went to Funding Required, was funded). A
proposal's name, author, date, goal, stage, milestone counts, link and tags are its front
matter's, as the gate reads it itself from the repository (ccs-bash's own `lib/frontmatter.awk`,
in the gate's image; `fronts`, `ccs-check pages`' front.go), on its page and on its cards; a
sidebar's tag and a tag page are a tag some proposal has. Nor anything once the web
server itself is taken over: then ccs-watch and visitors are the defence. The checks are
`ccs-check` ([ccs-check.md](ccs-check.md): Go, memory-safe, one static binary). The donation
boxes' QR codes are never made or decoded here: each is the signed list's file of its address,
taken by its sum, and the web server has no qrencode. No image is read at all: a proposal's is
the proposals repository's, byte for byte, and what it shows (an address, a QR code of one) is
that repository's review's to catch, as its text's links are.

### The heartbeat: the web server notices a silent backend

A backend that is off, or cut off, can't alert. Each push (every run, a failed one too) is its
heartbeat: the gate notes it, and a timer here alerts when none has come for 15 minutes
(`HEARTBEAT_MINUTES` in `alert.conf`); not before the first push, nor while the web server has been
up less than that, and only on the second late check in a row. Then once an hour, and one line
when pushes return:

```
[CCS-watch] no push from the backend for 17 minutes: is it running? (its loop, its push key, its network) @ https://<site>
[CCS-watch] pushes from the backend arrive again @ https://<site>
```

`ccs-receive --heartbeat`, as ccs-data (the push key can't pass it arguments), every 5 minutes:
the web server compose's `heartbeat` service.
`tests/gate.sh` checks each of those cases.

## Watching the web server: the backend raises the alarm

`contrib/ccs-watch`, on the backend after each push and between pushes, fetches the pages that ask for donations
(home, Funding Required, Donate, Verify, each funding-required proposal), every file they use
(stylesheets, fonts, icons, the General Fund's QR code, proposal images: a stylesheet can hide an
address), `WATCH_SAMPLE` (10) other pages at random (any page could get a donation box) and
`/projects`, and compares each byte for byte with what was last pushed. A difference alerts the
second time it is seen within a day (runs that see the right page in between or not), naming the
page and any address not on the list; a recheck that isn't answered counts as still different. So
does a page answering anything else three checks in a row while the site answers, a page never
pushed answering anything but the 404 page, and the theme button leading anywhere but the page.

To make it harder for the web server to serve it the right pages and visitors others, it asks
as one of three browsers, picked at random each run: Tor Browser, Firefox or Chrome, each with its
own user agent and headers (`Sec-Fetch-*` by what is fetched, a page typed in, clicked on the site
or from another at random; keep their versions current with `WATCH_FIREFOX_ESR`, `WATCH_FIREFOX`,
`WATCH_CHROME`). It asks in no fixed order, each page and each file the pages use under `/`,
`/dark/` or `/light/` at random (`WATCH_THEMES=1`), through a proxy picked at random each fetch;
among them, at a random place, a page never pushed, named as the site's own are, and the theme
button on a page. It runs right after each push and between pushes at random times
(the compose's `watch` does both, [docker](docker.md)), so a web server that serves its own pages once
the check after a push is over is seen too.

A web server can still tell it apart: a page fetched without its stylesheets and fonts, and curl's
TLS handshake. The never-pushed page catches a web server that serves its own page at any name, not
one that adds pages at names it picks. Tor alone isn't enough (its exits are public): add a
clearnet proxy on another network (`ssh -D 1080 <machine>`, kept up by a service), and if you can,
a second ccs-watch elsewhere.

Alerts go to one URL as a plain-text POST: an IRC bot (CptHook's `simple` module,
`https://<host>/<endpoint>?channel=%23<channel>`), ntfy, or anything that takes a POST; or wmb's
`/directedMessage` with `ALERT_TARGET` and `ALERT_PASSWORD` (the bot must be in the channel).
`ccs-watch --test https://<the site>` sends one. Its config, readable only by root and the
watch's user:

```
install -m 640 -g ccs-watch /dev/null /etc/ccs/alert.conf
cat > /etc/ccs/alert.conf <<'CONF'
ALERT_URL=https://<the bot>/simple?channel=%23<channel>
SUBADDRESSES=/etc/ccs-front/subaddresses.txt        # to name addresses not on the list
WATCH_PROXY=socks5h://host.docker.internal:9050 socks5h://host.docker.internal:1080   # one at random a fetch: Tor (apt install tor) and a clearnet one elsewhere, on the bridge's address (handover, 1)
WATCH_THEMES=1                                      # also /dark/ and /light/ (the theme lines above)
WATCH_SAMPLE=10                                     # other pages, at random, each run
CONF
```

It runs after each push (also exit 7: a web server that lies can't hide behind a held-back page),
and is given how each run went (the compose's `push` hands it each run's result), so a stopped backend is an alarm too. One alert per problem
an hour; "could not be fetched" after three checks; "the backend has failed N runs in a row" after
three failed runs (about six minutes), and "runs again" after: [every line](troubleshooting.md#what-irc-says).
A careful attacker on the web server can still tell the watcher apart (above). Hence the Verify
page, asking visitors to check the address their wallet shows. `tests/watch.sh` runs it against a
local web server and a fake bot, including web servers that try each trick above.

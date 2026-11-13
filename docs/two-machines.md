# Two machines: the backend pushes, the web server only receives

The backend takes no incoming connections; after each run it pushes `site-data.json`, what only
it knows, to the web server, whose push key runs only the gate: it checks the data, builds the
site from it and checks what it built, and Caddy serves what passed. The gate and its heartbeat run from the gate's attested image, with their own sshd on
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

The push is `site-data.json` as it is, when it changed (the backend's [`contrib/ccs-push`](../contrib/ccs-push),
over this key, asking for `receive`), taken by the gate's own Go code (`ccs-check receive`), never
by rsync or any other C program, into its staging folder, so:

| If the key is stolen, this stops | |
|---|---|
| `restrict` | shells, forwarding, a terminal |
| `command=` the gate, which takes `receive` only | any other command (a shell, scp, rsync, reading back) |
| `ccs-check receive`: one file, `site-data.json`, at its own name in the folder | writing anything else, anywhere else: there is no name in the push to say where |
| its limits: 4 MB, a JSON object, 5 minutes | filling the disk, holding the gate, a page or anything else as the push |
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
`CCS_ONION`: the gate builds every page's footer with it, so a backend can't point visitors at
another onion. The onion's key, `/var/lib/ccs-tor/ccs/hs_ed25519_secret_key`,
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

The push (`site-data.json` when it changed since what the gate last took, else nothing, the
heartbeat: `contrib/ccs-push`) goes
to `CCS_PUSH_PORT` (2223) of the compose's `.env`. The web server needs 2223 open to the backend only (the backup machine: 2224)
and 80/443 to everyone, in its firewall *and* a cloud provider's (an Oracle security list, an AWS
security group). The admins' own ssh: [admin access](admin-access.md).

`tests/gate.sh` sends a page, an older backend's tar and 5 MB from the backend's key: each is
refused, nothing live changes; `tests/web.sh` tries other commands, forwarding and another
machine; `contrib/ccs-check/build.sh test` the receiver itself. A taken-over backend can still send a false `site-data.json`: the
gate is for that.

## The gate: the web server builds the site itself

`contrib/ccs-receive`, the push key's forced command. The backend sends no pages: the push is
`site-data.json` alone, what only the backend knows (each proposal's subaddress *index*, its dates
and funds, and the ideas). The web server builds every page itself, from that, the proposals
repository it fetches, the design and the signed list installed here. Each push, one at a time, it

1. receives the push into an empty staging folder (`ccs-check receive`: `site-data.json`, as
   above). None (it didn't change): the live site's is built from. Built again only when what the site is built from
   changed (`site-data.json`, the list, its QR codes, `allowed`, the design, the proposals commit
   fetched, `proposals.conf`, the gate), and once a day whatever happens;
2. fetches the **proposals repository** (`proposals.conf`), all its history (about 3 MB; the last
   fetch if it can't): each proposal's text, front matter and images come from here, reviewed
   and merged, never from the backend; and its **merge request**, read from GitLab's merge commits
   ("See merge request monero-project/ccs-proposals!522": the one that added the proposal's
   file), linked under `MERGE_REQUESTS`, and only to the repository itself (its own address or
   `LINK_HOSTS`': a message naming another project on the forge, anyone's, gives no link). A
   proposal's own `gitlab_url` (its front matter) is its link only if it is a merge request of
   the repository itself, and then it wins (a file added twice: the oldest merge commit isn't
   always the proposal's);
3. checks **`site-data.json`** (`ccs-check data`): every key once, byte for byte as ccs-bash
   writes it (Go's decoder would read `STATE` or `Subaddr_Index` as the key, where jq, which
   builds the site, reads only the exact one), and no other; each value of its kind; each index
   one the signed list has, never 0 (the wallet's main address), one proposal's only, and, for a
   proposal the live site has given an address, that one: the gate keeps its own record of them,
   `/var/lib/ccs-gate/pins`, each written as the proposal first goes live with it, never changed
   by a push, so no index, or no state at all, is held back too (a push can't hide a proposal to
   give it another address next time, nor give its address to another proposal, while the
   proposal is in the repository: a renamed one's goes with it; a person lets one go:
   [troubleshooting](troubleshooting.md#a-proposals-page-isnt-updating-old-text-old-totals)); amounts and dates as ccs-bash writes them; an idea's name and
   author plain printable ASCII text (escaped, 1000 characters at most: no letter of another
   script can stand in for an address's, no run of 90 base58 characters, and no address in
   groups either, read as step 5 reads one), its link a merge
   request of the proposals repository itself (its address, host and path, and `LINK_HOSTS`: not
   another repository on its forge, which anyone can make). One that fails is held back: the live
   site stays as it is, and IRC is told. One that passes is written again as it was read, and
   the site is built from that copy, never from the bytes pushed (the live site's
   `site-data.json` is that copy too);
4. **builds the site** (`ccs-gate-build`): ccs-bash's own steps for the site's JSON (`site.jq`,
   each address the signed list's line of its index) and the ccs-front-bash release the image
   vendors, with the newest design release; each QR code the signed list's own file of its address
   (`subaddresses.txt.qr/`, installed here); a proposal's text without its bidi controls
   (`ccs-check nobidi`: they show what follows them in another order than written; 36c3.md has
   one, pasted with a number), then escaped by ccs-front-bash's
   `markdown.awk`. A build that fails: the live site stays as it is, and IRC is told;
5. checks **what it built** (`ccs-check gate`): every address (95 or 106 base58 characters) in its
   pages, JSON and feed against the signed list and `allowed`, as written (tags and attributes
   too, entities decoded, an unknown named entity failing the file, non-ASCII characters dropped:
   a letter of another script drawn as an address's isn't read as one, so the ideas, anyone's
   text, are ASCII only; one in groups
   split by up to three spaces or punctuation, `4A9b - xZq3`, `4A9b/xZq3`, or split between two
   elements a browser lays side by side, where its checksum says it is one), the JSON as JSON
   too; none in the feed; no `data:` image, no NUL byte, no bidi control (U+202A-202E,
   U+2066-2069, U+200E, U+200F, U+061C, as itself or an entity: it shows the text after it in another order than it is
   written, an address written backwards the right way round: the build drops those in a
   proposal's text, so one here came another way). A file that needs more than 3000
   checksums or 20 s fails alone ("too many runs that could be addresses"). And every QR code,
   `qr/<address>.png`, exactly the signed list's file of that address (its sum in
   `subaddresses.txt.qr.sha256`, which the `.pin`'s `qr` line pins). This is the backstop for an
   address in a proposal's own text (the repository's review is the first check of that);
6. copies the site live (`ccs-check copy --delete`: each file written beside its live copy and
   renamed over it, 644; what the build no longer has, a proposal taken out of the repository,
   goes). A file that failed step 5 is left out, so its live copy goes too, and IRC is told: one bad
   page doesn't stop the rest. IRC is told of any page leaving the site, failed or not. But more
   than 3 pages leaving within a day (`CCS_GATE_REMOVE`, counted over the last 24 hours,
   `/var/lib/ccs-gate/removed`: failed, or their proposals gone: a branch emptied, a forge
   answering wrong, a backend hiding them a few at a time): none of the build that would add to
   them goes live, and IRC is told; a person decides (`/var/lib/ccs-gate/allow-remove` lets them
   go, for one build, and starts the count again: [troubleshooting](troubleshooting.md#what-irc-says)).
   A copy that fails part-way is said and alerted, not left for the next push;
7. refuses every push without its pinned list (or with one of no addresses), the QR codes' sums
   the `.pin` names, the QR codes, a design release (`design/vX.Y.Z/`), `proposals.conf`,
   `ccs-check`, `ccs-gate-build` or `git`.

The push's answer is its exit: 0, or 1 (nothing new went live); why: `journalctl -t ccs-gate`
(and `/var/log/ccs-gate.log` if created), and IRC. With `/etc/ccs-gate/alert.conf` it tells IRC
itself (once an hour per address or file, three a push, a foreign address first, also when the
backend hangs up mid-build): the alarm that still sounds when the backend is the one lying. Every
line it sends, and what to do: [troubleshooting, What IRC says](troubleshooting.md#what-irc-says).

Set it up once, as root (in Docker, then [its own steps](docker.md#setting-it-up-1)):

```
install -d -o ccs-data -m 755 /var/lib/ccs-staging
install -d -m 755 /etc/ccs-gate /etc/ccs-gate/design
install -d -o ccs-data -m 755 /var/lib/ccs-gate                      # one push at a time, the last push (the heartbeat), when it last alerted, the proposals fetched
install -m 640 -g ccs-data /dev/null /etc/ccs-gate/alert.conf        # optional: the bot (as ccs-watch's, plain text POST)
printf 'ALERT_URL=http://<bot>:8086/<path>\nSITE_URL=https://<site>\n' > /etc/ccs-gate/alert.conf
# (SITE_URL: also the feed's links and the link card's image, the backend's CCS_SITE_URL)
# the signed list, its pin, signature and key (ccs-front-bash, setup step 5); its view key file too, if the backend has one
install -m 644 subaddresses.txt subaddresses.txt.pin subaddresses.txt.asc subaddresses.txt.key.asc subaddresses.txt.viewkey subaddresses.txt.qr.sha256 /etc/ccs-gate/
# its QR codes (tools/make-qr.sh's), each checked against its sum
install -d -m 755 /etc/ccs-gate/subaddresses.txt.qr && install -m 644 subaddresses.txt.qr/*.png /etc/ccs-gate/subaddresses.txt.qr/
(cd /etc/ccs-gate/subaddresses.txt.qr && sha256sum -c --quiet ../subaddresses.txt.qr.sha256)
cat > /etc/ccs-gate/allowed <<'LIST'                                # other addresses allowed on the site, one a line
888tNkZrPN6JsEgekjMnABU4TBzc2Dt29EPAvkRxbANsAnjyPbb3iQ1YBRk1UXcdRsiKc9dhwMVgN5S9cQUiyoogDavup3H  # the General Fund
LIST
# the proposals repository the backend reads (its checkout's origin), and its branch; LINK_HOSTS:
# other places an idea's link may go to, as host/path of a repository (an older forge its merge
# requests were on: repo.getmonero.org/monero-project/ccs-proposals); MERGE_REQUESTS: the forge
# whose "See merge request <project>!N" the repository's merge commits end with (none: no links)
printf 'PROPOSALS_GIT=https://repo.getmonero.org/monero-project/ccs-proposals.git\nPROPOSALS_BRANCH=master\nMERGE_REQUESTS=https://repo.getmonero.org\n' > /etc/ccs-gate/proposals.conf
```

The list's files: as [the signed list](signed-list.md) says, checked for this machine too (a
taken-over backend would bring both a list and the sums it is compared with).

**The design**, the release zip the backend runs, unpacked:

```
v=v0.1.31                                                            # the handover's releases table
sha256sum ccs-front-hugo-$v.zip                                      # the attested one
unzip -q ccs-front-hugo-$v.zip -d /etc/ccs-gate/design/$v
```

Each design in `design/` named as its release (`v0.1.25`): the gate builds with the newest, and
takes no other folder there (a build of the design's left beside them is no design). A new
design: unpack it beside the old one; the old can go once the new is live. Empty
`/var/lib/ccs-data` before the first push if anything is in it (the build replaces it).

A proposal quoting another address goes off the site until that address is in `allowed` (the log
names it; on the testnet, two). A new list: its files and QR codes, the same way.

`tests/gate.sh` builds this in the gate's image, with the design's real release, and pushes each
way around it, each case named in its output:

- **built and live:** a push of `site-data.json`; each proposal's merge request link; a donation,
  a proposal edited (its link still the merge request that added it); built again when what it's
  built from changes, or a day later; not again for the same data;
- **held back:** a `site-data.json` with an index the list hasn't, 0, another than the live
  site's, none where the live site has one, a key more, a key in another case or twice, markup or
  an address in an idea (in groups, a letter Cyrillic), a link out of the repository, a proposal
  the repository hasn't;
- **off the site:** a proposal's page with an address that isn't the wallet's (as written, in
  groups, split by markup, a letter Cyrillic, written backwards after a bidi override), back
  once mended; a QR code that isn't the list's; a proposal taken out of the repository (IRC
  told); four at once held, and four one a push within a day (`allow-remove` lets them go); a
  front matter `gitlab_url` out of the repository doesn't replace the merge request link;
- **refused, every push:** a page or anything else pushed; no design release, no QR codes, a list
  that isn't the pinned one, QR codes' sums that aren't, an empty list; an older backend's tar,
  a push over 4 MB (saying why);
- **through:** the repository down (one alert after 6 hours); two pushes at once; a backend that
  hangs up mid-build; no `alert.conf` (it is optional).

**What it can't see:** what only the backend knows: a total, count or percentage that is wrong but
a number; an idea that is no merge request (still escaped text linking to the repository); which
of the list's addresses a proposal new to the site is first given (one no other proposal has: from
then on it is that proposal's); the dates only the backend keeps (when a proposal went to Funding
Required, was funded). Nor anything once the web server itself is taken over: then ccs-watch and
visitors are the defence. The checks are `ccs-check` ([ccs-check.md](ccs-check.md): Go,
memory-safe, one static binary); the build is ccs-bash's `site.jq` and the vendored ccs-front-bash
(bash, jq, awk: [the web server](web-server.md)). No image is read at all: a proposal's is the
proposals repository's, and what it shows (an address, a QR code of one) is that repository's
review's to catch, as its text's links are.

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
(home, Funding Required, Donate, Verify, each funding-required proposal), `WATCH_SAMPLE` (10)
other proposals' pages at random (any page could get a donation box) and `/projects`, and checks
their addresses: every address on them (95 or 106 base58 characters, as text or link) the signed
list's or `WATCH_ALLOWED`'s (the General Fund, and what the gate's `allowed` has); each
funding-required proposal's donation box its own address, as ccs-bash gave it (`projects.json`),
and its QR code the list's own file of it; and every image on a page one it knows byte for byte
(a file of the design release, its sums in `/etc/ccs-front/design.sha256`; a QR code of the
list's; a proposal's image as the backend's proposals checkout has it), so a picture of another
address's QR code, put anywhere on a page, alerts too, though nothing reads what an image shows.
The web server builds the pages itself, so they aren't
compared with anything the backend made: what this sees is a web server serving a visitor an
address that isn't the wallet's. A wrong page alerts the second time it is seen within a day
(runs that see the right page in between or not), naming any address not on the list; a recheck
that isn't answered counts as still wrong. So does a page answering anything else three checks in
a row while the site answers, a page that doesn't exist answering anything but a 404, and the
theme button leading anywhere but the page.

To make it harder for the web server to serve it the right pages and visitors others, it asks
as one of three browsers, picked at random each run: Tor Browser, Firefox or Chrome, each with its
own user agent and headers (`Sec-Fetch-*` by what is fetched, a page typed in, clicked on the site
or from another at random; keep their versions current with `WATCH_FIREFOX_ESR`, `WATCH_FIREFOX`,
`WATCH_CHROME`). It asks in no fixed order, each page under `/`, `/dark/` or `/light/` at random
(`WATCH_THEMES=1`), through a proxy picked at random each fetch; among them, at a random place, a
page that doesn't exist, named as the site's own are, and the theme button on a page. It runs right after each push and between pushes at random times
(the compose's `watch` does both, [docker](docker.md)), so a web server that serves its own pages once
the check after a push is over is seen too.

A web server can still tell it apart: a page fetched without its stylesheets and fonts, and curl's
TLS handshake. Nor does it see a stylesheet that hides an address or shows another: the gate builds
those from the design, and a web server taken over could change them; the Verify page is the
visitor's check. The page that doesn't exist catches a web server that serves its own page at any
name, not one that adds pages at names it picks. Tor alone isn't enough (its exits are public): add a
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
SUBADDRESSES=/etc/ccs-front/subaddresses.txt        # the signed list (and its QR codes beside it, .qr/)
WATCH_ALLOWED=888tNkZrPN6JsEgekjMnABU4TBzc2Dt29EPAvkRxbANsAnjyPbb3iQ1YBRk1UXcdRsiKc9dhwMVgN5S9cQUiyoogDavup3H   # the web server's allowed addresses, space-separated
WATCH_PROXY=socks5h://host.docker.internal:9050 socks5h://host.docker.internal:1080   # one at random a fetch: Tor (apt install tor) and a clearnet one elsewhere, on the bridge's address (handover, 1)
WATCH_THEMES=1                                      # also /dark/ and /light/ (the theme lines above)
WATCH_SAMPLE=10                                     # other proposals' pages, at random, each run
CONF
```

It runs after each push, and is given how each run went (the compose's `push` hands it each run's result), so a stopped backend is an alarm too. One alert per problem
an hour; "could not be fetched" after three checks; "the backend has failed N runs in a row" after
three failed runs (about six minutes), and "runs again" after: [every line](troubleshooting.md#what-irc-says).
A careful attacker on the web server can still tell the watcher apart (above). Hence the Verify
page, asking visitors to check the address their wallet shows. `tests/watch.sh` runs it against a
local web server and a fake bot, including web servers that try each trick above.

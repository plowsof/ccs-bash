# Two machines: the backend pushes, the web server only receives

The backend takes no incoming connections; after each run it pushes the site to the web server,
whose push key runs only the gate: it checks every file before it goes live, and nginx serves what
passed. In Docker, the production setup, the gate and its heartbeat run from the gate's attested
image, with their own sshd on port 2223 ([the web server in Docker](docker.md#the-web-server-in-docker));
nginx stays on the host. Without Docker, the host's sshd and a timer do it ([below](#without-docker)).

**The push account:**

```
install -d -m 755 /var/empty                              # its home: root's and empty (bash, git and curl read config from a home)
useradd --system --no-create-home --home-dir /var/empty --shell /bin/sh ccs-data   # no password; only the forced command runs (an existing one: usermod -d /var/empty ccs-data)
install -d -o ccs-data -m 755 /var/lib/ccs-data           # ideally its own small filesystem or a quota
install -d -m 755 /etc/ssh/authorized_keys                # root-owned, outside the account's home
# /etc/ssh/authorized_keys/ccs-data (root, 644):
from="<backend IP>",command="/usr/local/bin/ccs-receive",restrict ssh-ed25519 AAAA... ccs-bash
```

The gate receives with `ccs-check rrsync` (as rrsync `-wo -no-del -munge`, and only the
backend's own push: `rsync -a --delay-updates SITE/ host:`) into its staging folder, so:

| If the key is stolen, this stops | |
|---|---|
| `restrict` | shells, forwarding, a terminal |
| `-wo` | reading back, writing outside the folder |
| `-no-del` | deleting |
| `-munge` | symlinks (a `projects.json` link to any file would get nginx to publish it) |
| `from=` | use from another machine |
| key file root-owned, outside its home | loosening the key line, adding a key |
| own filesystem / quota | filling the disk |

**nginx.** The security headers, in `/etc/nginx/snippets/ccs-headers.conf` (beta.getmonero.org's,
with a stricter CSP; A+ on securityheaders.com):

```
add_header Content-Security-Policy "default-src 'none'; style-src 'self'; img-src 'self' data:; font-src 'self'; frame-ancestors 'none'; base-uri 'self'; form-action 'none'" always;
add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
add_header X-Content-Type-Options "nosniff" always;
add_header X-Frame-Options "DENY" always;
add_header Referrer-Policy "no-referrer" always;
add_header Permissions-Policy "accelerometer=(), ambient-light-sensor=(), autoplay=(), battery=(), camera=(), clipboard-read=(), clipboard-write=(), display-capture=(), document-domain=(), encrypted-media=(), fullscreen=(), geolocation=(), gyroscope=(), hid=(), idle-detection=(), interest-cohort=(), magnetometer=(), microphone=(), midi=(), payment=(), picture-in-picture=(), publickey-credentials-get=(), screen-wake-lock=(), serial=(), sync-xhr=(), usb=(), xr-spatial-tracking=()" always;
add_header X-XSS-Protection "0" always;
```

and the site, in `/etc/nginx/sites-available/ccs`, linked into `sites-enabled/` in place of
Debian's `default` (also a `default_server`: `nginx -t` refuses both):

```
map $uri $ccs_cache {                               # in the http context, e.g. at the top of the file
    "~\.[0-9a-f]{64}\.(css|png|avif|woff2)$" "public, max-age=31536000, immutable";
    /assets/general-fund-qr.png        "public, max-age=86400";   # on every page; the same file for good
    default                            "no-cache";
}
server {
    listen 80 default_server;
    root /var/lib/ccs-data;
    index index.html;
    disable_symlinks on;
    server_tokens off;                              # no nginx version in headers and error pages
    charset utf-8;                                  # pages are UTF-8, whatever a page says
    include snippets/ccs-headers.conf;
    add_header Cache-Control $ccs_cache always;
    gzip on;                                        # text compressed (Debian's nginx: HTML only), not images
    gzip_types text/css text/xml application/xml application/json;
    gzip_vary on;
    error_page 404 /404.html;                       # a missing page, or a folder without one: the site's own
    error_page 403 =404 /404.html;
    location / {
        try_files $uri $uri/ =404;
    }
    location ~ \.avif$ {                            # nginx before 1.25 has no AVIF in mime.types
        types { }
        default_type image/avif;
        include snippets/ccs-headers.conf;
        add_header Cache-Control $ccs_cache always;
        try_files $uri =404;
    }
    location = /projects {                          # the site carries projects.json
        alias /var/lib/ccs-data/projects.json;
        default_type application/json;
        include snippets/ccs-headers.conf;
        add_header Cache-Control "no-cache, must-revalidate";
    }
}
```

A `location` with its own `add_header` drops the server's, hence the `include` again. Files named
by their hash (the stylesheet, icons, font, the home page's pictures) are kept by browsers for a
year, the General Fund's QR code (on every page, never changing) a day, the pages not at all: a
visitor on a slow Tor circuit fetches each file once. `charset
utf-8` overrides any `<meta charset>`, so a page can't switch to an encoding where bytes the gate
read as text show as something else. A missing page or folder answers the site's 404 (403 would
say it exists); ccs-watch reads any answer but 200 as the page not served.

| Header | Stops |
|---|---|
| `Content-Security-Policy` | anything loading from another site, any script, inline styles; `frame-ancestors 'none'`: another site showing a page in a frame with its own address drawn over the donation box (`default-src` doesn't cover it); `base-uri 'self'`: for the 404 page's `<base href="/">` |
| `Strict-Transport-Security` | plain HTTP once a browser has seen HTTPS, so nobody on the way can strip it (ignored over HTTP, so harmless on port 80). No `preload`: that is for a whole domain |
| `X-Content-Type-Options` | a file run as a script or stylesheet when nginx says it is something else (not images: a browser shows any image bytes, hence the gate's rule that pages start as text) |
| `X-Frame-Options` | framing, for browsers older than `frame-ancestors` |
| `Referrer-Policy` | other sites learning which page a visitor came from |
| `Permissions-Policy` | every browser feature the site doesn't use (camera, payment, clipboard…) |
| `X-XSS-Protection: 0` | old browsers' XSS filters, which could be used to blank parts of a page; the CSP is the protection |

**Caching:** stylesheets, icons and fonts are named by their hash (`style.<sha256>.css`), so
browsers keep them for good (no layout shift, even on Tor); everything else is `no-cache`, checked
before reuse. The regex is quoted (its `{64}` would open a block); a `map`, not a `location`,
because `/dark/` and `/light/`'s `^~` would win.

**The theme** (Light, Dark, System), kept in the address, without cookies or JavaScript: `/dark/…`
and `/light/…` are the same files with another `assets/theme.css`, and the button's
`?theme=light|dark|system` redirects to the page under that prefix (links are relative, so it
stays). In the `server` (the `map` in the `http` context):

```
map $request_uri $ccs_page {                       # the page, without a theme prefix or query
    ~^/(?:dark|light)(/(?:[^/?\x5c][^?]*)?)(?:\?|$) $1;
    ~^(/(?:[^/?\x5c][^?]*)?)(?:\?|$)               $1;
    default                                      /;
}

    if ($arg_theme = light)  { return 302 /light$ccs_page; }
    if ($arg_theme = dark)   { return 302 /dark$ccs_page; }
    if ($arg_theme = system) { return 302 $ccs_page; }
    location = /dark/assets/theme.css  { alias /var/lib/ccs-data/assets/theme-dark.css; }
    location = /light/assets/theme.css { alias /var/lib/ccs-data/assets/theme-light.css; }
    location ^~ /dark/  { alias /var/lib/ccs-data/; try_files $uri $uri/ =404; }
    location ^~ /light/ { alias /var/lib/ccs-data/; try_files $uri $uri/ =404; }
```

These are the very files the gate checked and ccs-watch compares. The map never yields an address
starting `//` or `/\` (`\x5c`: nginx reads `\\` itself), which a browser takes as another site's
(`absolute_redirect on`, the default, stops that too; behind a proxy it may be off). Without these
lines the button only reloads the page.

**HTTPS:** a DNS A record, `server_name`, then `certbot --nginx -d <name> --redirect` (`apt install
certbot python3-certbot-nginx`): the 443 server, a redirect from 80, renewed by `certbot.timer`.

**An onion service** (optional): the same site for Tor Browser users, without an exit node. Tor
publishes it, nginx serves the very files and headers the clearnet site does (the site's body in
one snippet, `snippets/ccs-site.conf`, both servers including it), and the clearnet site says so
(`Onion-Location`, which Tor Browser turns into ".onion available"):

```
# /etc/tor/torrc, then: systemctl reload tor; cat /var/lib/tor/hidden_service/ccs/hostname
HiddenServiceDir /var/lib/tor/hidden_service/ccs
HiddenServicePort 80 127.0.0.1:8096
# sites-available/ccs: the server's body (root ... the /light/ location) moved to snippets/ccs-site.conf
server {
    listen 127.0.0.1:8096;
    server_name <name>.onion;
    port_in_redirect off;          # the theme button's redirect names the onion, not this port
    include snippets/ccs-site.conf;
}
# snippets/ccs-headers.conf (Tor Browser ignores it on the onion itself)
add_header Onion-Location "http://<name>.onion$request_uri" always;
```

The footer says so too: the address in `/etc/ccs-gate/onion` (root, 644), and the same in the
backend compose's `.env` as `CCS_ONION`, which ccs-front-bash writes in every page's footer. The
gate takes the footer's onion line only with the address in its own file: a backend can't point
visitors at another onion. The onion's key, `/var/lib/tor/hidden_service/ccs/hs_ed25519_secret_key`,
is the onion's identity, as the TLS key is the clearnet site's: back it up as root, show it no one.

**The backend's key**, the push stage's, and the gate's own host key on its port, from the web
server's `/etc/ccs-gate/ssh/ssh_host_ed25519_key.pub` (not accepted on first connect):

```
install -d -o ccs-push -m 700 /etc/ccs/push
runuser -u ccs-push -- ssh-keygen -t ed25519 -N '' -f /etc/ccs/push/id_ed25519
echo "[<web server>]:2223 ssh-ed25519 AAAA..." > /etc/ccs/push/known_hosts
```

The push (`--checksum`: only the files whose contents changed, as each run makes every file anew;
`--delay-updates`: swapped in once all have arrived) goes to `CCS_PUSH_PORT` (2223) of the
compose's `.env`. The web server needs 2223 open to the backend only (the backup machine: 2224)
and 80/443 to everyone, in its firewall *and* a cloud provider's (an Oracle security list, an AWS
security group). The admins' own ssh: [admin access](admin-access.md).

`tests/rrsync.sh` tries all of the above from the backend's key in containers (commands,
forwarding, reading back, `..`, `--temp-dir`, `--backup-dir`, `--link-dest`, deleting, symlinks,
another machine): all refused, on rrsync as documented and on `ccs-check rrsync` (the gate's,
`CCS_CHECK=`), and with rrsync alone (`--loose`) they get through, so the test catches them. A taken-over backend can still push false pages: the gate is for that.

## The gate: the web server checks every page

`contrib/ccs-receive`, the push key's forced command. It doesn't guess how a browser shows
what it is sent; it knows what a page may be. Each push, one at a time, it

1. makes a staging folder a copy of the live site, and receives the push into it (`ccs-check
   rrsync`: the backend's push, nothing else; `--munge-links`). What it checks below are the
   files the push changed, and the ones it held back last time (their last good copy is live, so
   the same file sent again fails again): the live site holds only what passed. Every page and JSON file is checked again
   when what they were checked against changes (the list or its pin, `allowed`, the design,
   `markdown.awk`, `proposals.conf`, the proposals commit fetched, `ccs-receive` itself or
   `ccs-check`), and once a day whatever happens; then the QR codes in the proposal images
   already live are read again too (one that fails stays as it was, and IRC is told). Its log says how many: `checking 3 of 1022 pages and JSON files`;
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
     proposal's), the same in its text and `monero:` link, its QR code that address's.

   A page not checked in time (5 minutes) or over 8 MB is held back: what isn't known good
   doesn't go live;
3. checks **every address** (95 or 106 base58 characters) in pages and JSON against the signed
   list and `allowed`, as written (tags and attributes too, entities decoded, a non-ASCII
   character read both as nothing and as a space; one in groups split by up to three spaces or
   punctuation, `4A9b - xZq3`, `4A9b/xZq3`, where its checksum says it is one), the JSON as JSON
   too, its strings read the same way. One pass, 2 minutes at most for all; a file that needs more
   than 3000 checksums or 20 s is held back alone ("too many runs that could be addresses"), not
   every file with it; and **every QR code**: each `data:image/png;base64,` image must be, pixel for pixel,
   `qrencode -s 10` of such an address. Pages and JSON must start with `<`, `[` or `{` (a
   browser shows `<img src="x.html">` by its bytes);
4. checks every other file the push changes: the design's, byte for byte (`design.sha256`: a
   stylesheet can hide an address, an image be a QR code); a proposal's image the proposals
   repository has, byte for byte at that path (its QR codes, inverted too, of listed addresses);
   `projects.json`; or the list's files as installed here. Each a plain file where the live site
   has one (a symlink or a folder in a page's place would take the page away);
5. copies staging into the live site, except a file that fails, which keeps its last good copy:
   one bad page doesn't stop the rest. The push then exits 7 (a refused one: 1); which file and
   why: `journalctl -t ccs-gate` (and `/var/log/ccs-gate.log` if created), and IRC. The one
   exception: a proposal page the push didn't send, whose proposal is in neither commit just
   fetched (not the last fetch), and with nothing else wrong, is a proposal taken out of the
   repository (its `.md` in neither commit's tree). The push can't delete, so the gate takes it,
   and its `images/<name>/`, off the live site, and the push is good; but never more than 3 at
   once (`CCS_GATE_REMOVE`): more (a branch emptied or rewritten, a forge answering wrong) stay
   held back, and IRC is told;
6. refuses the whole push without its pinned list, `design.sha256`, the design, `markdown.awk`,
   `proposals.conf`, `ccs-check`, `qrencode` or `git`, a design release (`design/vX.Y.Z/`), or
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
install -m 644 subaddresses.txt subaddresses.txt.pin subaddresses.txt.asc subaddresses.txt.key.asc subaddresses.txt.viewkey /etc/ccs-gate/
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

The list's files are the backend's (`/etc/ccs-front/`, checked there:
[handover](handover.md#4-the-signed-subaddress-list), step 4); check them here too, the same way
(`tools/verify-subaddresses.sh` with a `list-signers` of your own), not only against the backend's
sums: a taken-over backend would bring both.

**The design**, the release zip the backend runs, unpacked, and the sums of every file but the pages:

```
v=v0.1.24                                                            # the handover's releases table
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
refusal names it; on the testnet, two). A new list: its four files, the same way.

`tests/gate.sh` builds this in containers (with `GATE_IMAGE`, from the gate's image) and pushes
each way around it, each case named in its output:

- **held back:** an address split, disguised (entities, invisible or look-alike characters, bidi)
  or in a QR code of another address; a page or text that isn't the design's or the repository's;
  a link out of the repository; a stylesheet, image or list that isn't the installed one;
- **refused, every push:** no design or `markdown.awk`, a list that isn't the pinned one;
  deleting, and anything outside the folder;
- **checked again:** only what a push changed; a held-back file sent again unchanged; every page
  after a change to what it is checked against, or a day after the last full check;
- **through:** a good push after a held-back one; the repository down; two pushes at once;
- **alerts:** a check that stops holds back every page; a backend that hangs up mid-check.

**What it can't see:** what only the backend knows: a total, count or percentage that is wrong but
a number; an idea that is no merge request (still escaped text linking to the repository); one of
the wallet's subaddresses on another proposal's page (the money stays in the CCS wallet); a
proposal's name, author, dates, goal or stage as ccs-bash read its front matter (a renamed
proposal, a completed one with a donation box, a listed address still). Nor anything once the web
server itself is taken over: then ccs-watch and visitors are the defence. The checks are
`ccs-check` ([ccs-check.md](ccs-check.md): Go, memory-safe, one static binary). The backend's
QR codes are never decoded: each is compared, pixel for pixel, with qrencode's of the address it
must be. Only a proposal's images, from the proposals repository, are read for QR codes (Go's
own decoders, as the format the name says, the size checked first); one it can't check (over
8 MB or 40 million pixels, or not in time) is held back.

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
the web server compose's `heartbeat` service ([without Docker](#without-docker): a timer).
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
(in Docker the compose's `watch` does both, [docker](docker.md); the host setup:
`ccs-watch.timer`, [setup](setup.md#the-update-script-the-host-setup)), so a web server that serves its own pages once
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
watch's user (without Docker: `ccs`):

```
install -m 640 -g ccs-watch /dev/null /etc/ccs/alert.conf
cat > /etc/ccs/alert.conf <<'CONF'
ALERT_URL=https://<the bot>/simple?channel=%23<channel>
SUBADDRESSES=/etc/ccs-front/subaddresses.txt        # to name addresses not on the list
WATCH_PROXY=socks5h://host.docker.internal:9050 socks5h://host.docker.internal:1080   # one at random a fetch: Tor (apt install tor) and a clearnet one elsewhere, on the bridge's address (handover, 1); the host setup: 127.0.0.1
WATCH_THEMES=1                                      # also /dark/ and /light/ (the theme lines above)
WATCH_SAMPLE=10                                     # other pages, at random, each run
CONF
```

It runs after each push (also exit 7: a web server that lies can't hide behind a held-back page),
and is given how each run went (the compose's `push` hands it each run's result; without Docker,
the update script's `ccs-watch --run`), so a stopped backend is an alarm too. One alert per problem
an hour; "could not be fetched" after three checks; "the backend has failed N runs in a row" after
three failed runs (about six minutes), and "runs again" after: [every line](troubleshooting.md#what-irc-says).
A careful attacker on the web server can still tell the watcher apart (above). Hence the Verify
page, asking visitors to check the address their wallet shows. `tests/watch.sh` runs it against a
local web server and a fake bot, including web servers that try each trick above.

## Without Docker

The host's own sshd takes the push key, and a timer runs the heartbeat. As root, with the
folders and files above:

```
apt install rsync qrencode git   # the push received, the QR codes it compares with made, the proposals fetched
install -m 755 contrib/ccs-receive /usr/local/bin/ccs-receive        # from this repository at the attested commit, checked out here
install -m 755 ccs-check-vX.Y.Z-linux-amd64 /usr/local/bin/ccs-check  # the release's, its sha256 the notes' (see below)
install -o ccs-data -m 644 /dev/null /var/log/ccs-gate.log          # optional: the refusals, as a file (in Docker: /var/log/ccs-web/)
```

`ccs-check` is the release's asset (`ccs-check-vX.Y.Z-linux-amd64`): check `sha256sum` against
the notes' "ccs-check sha256". It is the attested gate image's own `/usr/local/bin/ccs-check`:
to check it against the attestation itself, pull the gate image by its digest, check its ID
(`docker image inspect`, the attested one), and copy it out (`docker create`, `docker cp`); or
build it (`contrib/ccs-check/build.sh OUT`, Docker, the same bytes).

At the end of `/etc/ssh/sshd_config`, then `systemctl reload ssh` (so sshd reads no other key file
for ccs-data: one in its own home it could replace):

```
Match User ccs-data
    AuthorizedKeysFile /etc/ssh/authorized_keys/%u
```

The heartbeat:

```
cat > /etc/systemd/system/ccs-heartbeat.service <<'UNIT'
[Unit]
Description=ccs-gate: alert when no push has come from the backend

[Service]
Type=oneshot
User=ccs-data
ExecStart=/usr/local/bin/ccs-receive --heartbeat
UNIT
cat > /etc/systemd/system/ccs-heartbeat.timer <<'UNIT'
[Unit]
Description=ccs-gate heartbeat, every 5 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload && systemctl enable --now ccs-heartbeat.timer
```

On the backend, the push key is `ccs`'s (`/var/lib/ccs/.ssh/id_ed25519`, made as above as `ccs`), its `known_hosts` the
web server's own host key (`/etc/ssh/ssh_host_ed25519_key.pub`) for `<web server>` on port 22,
and [the update script](setup.md#the-update-script-the-host-setup) pushes with `-p 22` in full, as
the backend's `ssh_config` may default to another port (a push that hangs is the sign). Keep the
QR reader's libraries updated (`unattended-upgrades`): the gate's image pins and attests them.

# ccs-front on another machine

The wallet machine then takes no incoming connections: after each run it pushes the output
to the web server, which can only receive those files into one folder.

| | ccs-bash machine | web server |
|---|---|---|
| Has | the wallet, ccs-bash (A or B), proposals checkout, state file | ccs-front with its own proposals checkout, nginx, `ccs-data` |
| Setup | [setup](setup.md) steps 1–3 and 7; step 6 with the push below | steps 4 and 5 with `/var/lib/ccs-data` |
| The image (B) | here only, ID checked here | no Docker needed |

**Web server:** an account that can only receive, with `rrsync` (rsync 3.2.4+;
`apt install rsync python3`):

```
useradd --system --create-home --shell /bin/sh ccs-data   # no password; only the forced command runs
install -d -o ccs-data -m 755 /var/lib/ccs-data           # ideally its own small filesystem or a quota
install -d -m 755 /etc/ssh/authorized_keys                # root-owned, outside the account's home
# /etc/ssh/authorized_keys/ccs-data (root, 644):
from="<wallet machine IP>",command="rrsync -wo -no-del -munge /var/lib/ccs-data",restrict ssh-ed25519 AAAA... ccs-bash
```

and in `/etc/ssh/sshd_config` (at the end: a `Match` lasts to the next one), then `systemctl reload ssh`:

```
Match User ccs-data
    AuthorizedKeysFile /etc/ssh/authorized_keys/%u
```

The account owns its home, so a key file there (even in a root-owned `.ssh`, which it could rename)
is one it could replace; this one it can't, and sshd reads no other for it.

| If the key is stolen, this stops | |
|---|---|
| `restrict` | shells, forwarding, a terminal |
| `-wo` | reading back, writing outside the folder |
| `-no-del` | deleting |
| `-munge` | symlinks (a `projects.json` link to any file would get nginx to publish it) |
| `from=` | use from another machine |
| key file root-owned, outside its home | loosening the key line, adding a key |
| own filesystem / quota | filling the disk |

Then either of two ways:

**A) With ccs-front-bash** (the site is made on the ccs-bash machine, see [the design](design.md)):
the web server only serves what arrives, nothing else is installed or run there. nginx:

The security headers, in a file of their own, `/etc/nginx/snippets/ccs-headers.conf` (as
beta.getmonero.org sends them, with a stricter CSP; an A+ on securityheaders.com):

```
add_header Content-Security-Policy "default-src 'none'; style-src 'self'; img-src 'self' data:; font-src 'self'; frame-ancestors 'none'; base-uri 'self'; form-action 'none'" always;
add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
add_header X-Content-Type-Options "nosniff" always;
add_header X-Frame-Options "DENY" always;
add_header Referrer-Policy "no-referrer" always;
add_header Permissions-Policy "accelerometer=(), ambient-light-sensor=(), autoplay=(), battery=(), camera=(), clipboard-read=(), clipboard-write=(), display-capture=(), document-domain=(), encrypted-media=(), fullscreen=(), geolocation=(), gyroscope=(), hid=(), idle-detection=(), interest-cohort=(), magnetometer=(), microphone=(), midi=(), payment=(), picture-in-picture=(), publickey-credentials-get=(), screen-wake-lock=(), serial=(), sync-xhr=(), usb=(), xr-spatial-tracking=()" always;
add_header X-XSS-Protection "0" always;
```

and the site:

```
map $uri $ccs_cache {                               # in the http context, e.g. at the top of the file
    "~\.[0-9a-f]{64}\.(css|png|woff2)$" "public, max-age=31536000, immutable";
    default                            "no-cache";
}
server {
    listen 80 default_server;
    root /var/lib/ccs-data;
    disable_symlinks on;
    server_tokens off;                              # no nginx version in headers and error pages
    charset utf-8;                                  # pages are UTF-8, whatever a page says
    include snippets/ccs-headers.conf;
    add_header Cache-Control $ccs_cache always;
    location = /projects {                          # the site carries projects.json
        alias /var/lib/ccs-data/projects.json;
        default_type application/json;
        include snippets/ccs-headers.conf;
        add_header Cache-Control "no-cache, must-revalidate";
    }
}
```

A `location` with its own `add_header` drops all of the server's, hence the `include` in each such
`location` again. `charset utf-8` puts `charset=utf-8` in each page's `Content-Type`, which a
browser takes over any `<meta charset>` in the page: a page can't switch itself to an encoding
where bytes the gate reads as text show as something else (the gate refuses such a `<meta>` too).
What the headers do:

| Header | Stops |
|---|---|
| `Content-Security-Policy` | anything loading from another site, any script, inline styles; `frame-ancestors 'none'`: another site showing a page in a frame with its own address drawn over the donation box (`default-src` doesn't cover it); `base-uri 'self'`: for the 404 page's `<base href="/">` |
| `Strict-Transport-Security` | once a browser has seen the site over HTTPS, plain HTTP to it, so nobody on the way can strip HTTPS and change the pages (browsers ignore it over HTTP, so it can stay in the port 80 server too). No `preload`: that is for a whole domain, not one name in it |
| `X-Content-Type-Options` | a browser running a file as a script or stylesheet when nginx says it is something else. It doesn't stop images: a browser shows an `<img>` of any file whose bytes are an image's, which is why the gate wants pages and JSON to start as text |
| `X-Frame-Options` | framing, for browsers older than `frame-ancestors` |
| `Referrer-Policy` | other sites learning which page a visitor came from |
| `Permissions-Policy` | every browser feature the site doesn't use (camera, payment, clipboard…), so nothing on a page can ask for them |
| `X-XSS-Protection: 0` | old browsers' XSS filters, which could be used to blank parts of a page; the CSP is the protection |

**Caching:** the stylesheet, the icons and the fonts are named by their content hash
(`style.<sha256>.css`), so browsers may keep them for good: a new design release gives them new
names. Everything else (the pages, remade each run, `theme.css`, `/projects`) is `no-cache`: the
browser checks before reusing it, and an unchanged file isn't sent again. Kept files are what stop
pages shifting as you click around, slow connections and Tor included: the font is already there
for the first paint. The regex goes in quotes (its `{64}` would otherwise open a block), and the
`map` covers `/dark/` and `/light/` too, where a `location` wouldn't (their `^~` wins).

**The theme** (Light, Dark or System, the button in the site's header) is kept in the address,
without cookies or JavaScript: `/dark/…` and `/light/…` are the same files, except that there
`assets/theme.css` is `theme-dark.css` or `theme-light.css`. The button's links are
`?theme=light|dark|system`, which nginx turns into the same page under that prefix. Every link
in the site is relative, so the prefix stays while browsing. In the `server`, beside the
`location`s above (and the `map` outside it, in the `http` context, e.g. at the top of the file):

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
    location ^~ /dark/  { alias /var/lib/ccs-data/; }
    location ^~ /light/ { alias /var/lib/ccs-data/; }
```

The pages are the very files the gate checked and ccs-watch compares, under another address.
The map never yields an address starting `//` or `/\` (`\x5c` is a backslash, written so because
nginx reads `\\` itself): a browser reads either as another site's (`?theme=system` on
`//evil.example/` would send it there). nginx's default `absolute_redirect on` stops that today,
but `absolute_redirect off` (common behind a proxy) wouldn't.
Without these lines the toggle just reloads the page in the browser's own setting.

HTTPS: point a DNS A record at the web server, set `server_name` to that name, then
`certbot --nginx -d <name> --redirect` (`apt install certbot python3-certbot-nginx`). It adds
the 443 server with the certificate and a redirect from 80, keeps the headers above, and
renews itself (`certbot.timer`).

**B) With Jekyll:** use `/var/lib/ccs-data` as ccs-front's `_data` (setup steps 4–5; add
`disable_symlinks on;` to the `/projects` block). ccs-front pulls its own proposals, cloned with
`git clone -c core.symlinks=false`, from the crontab of a user that owns `/opt/ccs-front`, not
root's (`crontab -u ccs-front -e`, see [setup](setup.md) step 6):

```
*/2 * * * * git -C /opt/ccs-front/proposals pull -q --ff-only ; cd /opt/ccs-front && jekyll build -q
```

**ccs-bash machine:** a key for `ccs`, and the web server's host key from its
`/etc/ssh/ssh_host_ed25519_key.pub` (not accepted on first connect):

```
install -d -o ccs -g ccs -m 700 /var/lib/ccs/.ssh
runuser -u ccs -- ssh-keygen -t ed25519 -N '' -f /var/lib/ccs/.ssh/id_ed25519
echo "<web server> ssh-ed25519 AAAA..." > /var/lib/ccs/.ssh/known_hosts
```

`ccs-bash-update` pushes; `--delay-updates` swaps the files in only once all have arrived.
**A)** push the site ccs-front-bash made: the `rsync` in [the handover](handover.md#9-the-update).

**B)** push the JSON for the web server's Jekyll:

```
#!/bin/sh
# /usr/local/bin/ccs-bash-update (chmod 755)
timeout -k 5 40 runuser -u ccs-git -- env HOME=/ git -C /var/lib/ccs/proposals pull -q --ff-only
{ ccs-bash-run && runuser -u ccs -- rsync -a --delay-updates \
    -e "ssh -p 22 -o BatchMode=yes -o StrictHostKeyChecking=yes" /var/lib/ccs/out/ ccs-data@<web server>: ; } >> /var/log/ccs-bash.log 2>&1
```

`-p 22`: the web server's ssh port, given in full, because the ccs-bash machine's own
`ssh_config` may default to another (a hung push that times out is the sign). The web server
needs 22 open to this machine, and 80/443 to everyone: in its own firewall *and*, on a cloud
VM, in the provider's (an Oracle security list, an AWS security group).

`tests/rrsync.sh` builds this in containers and tries all of the above from the wallet
machine's key (commands, forwarding, reading back, `..`, `--temp-dir`, `--backup-dir`,
`--link-dest` and friends, deleting, symlinks, another machine): all refused. With rrsync
alone (`--loose`) they get through, so the test does catch them.

A taken-over wallet machine can still push false pages or JSON: the gate below makes the web
server refuse any page that isn't the design's, filled as ccs-front-bash fills it, and any with an
address that isn't the wallet's ([Security](../README.md#security)).

## The gate (way A, recommended): the web server checks every page

The web server's last check, so a bad page has to get past two machines: `contrib/ccs-receive`,
a bash script, run by the push key instead of rrsync. It doesn't guess how a browser would show
what it is sent; it knows what a page may be. Each push, one at a time, it

1. makes a staging folder a copy of the live site, and receives the push into it (rrsync, with
   the same `-wo -no-del -munge`);
2. checks **every page against the design**: the design's release zip, unpacked here, has every
   page and every part ccs-front-bash fills them with (ccs-front-hugo's README, "What
   ccs-front-bash fills in"). A page must be one of the design's own, byte for byte outside its
   `<!-- ccs:… -->` regions, each region filled with the design's parts and each `{{slot}}` with a
   value of its kind:
   - a number, an amount or a date as ccs-bash writes them;
   - a name, author, tag or milestone: escaped text (no markup), with no run of 90 base58
     characters in it, joined by characters that aren't ASCII or not (so not an address, padded
     or split by a zero-width space);
   - a link to a proposal: the site's own page, or the proposals' forge (`proposals.conf`'s
     host, and `LINK_HOSTS`);
   - a proposal's text: exactly what ccs-front-bash's `markdown.awk`, installed here, makes of its
     file in the **proposals repository**, which the gate fetches itself each push (its last two
     commits, so a merge landing between the backend's pull and the push doesn't hold the page
     back; can't be fetched, the last fetch is used). Reviewed and merged: a backend can't change
     what a proposal says;
   - the donation box: an address, its QR code, the Verify link, the design's markup around them.

   So nothing else can be on a page: no markup the design doesn't have, no text where it puts
   none, no `<br>` or image or class inside an address, no QR code drawn as text, no link to
   another site except in a proposal's own reviewed text;
3. checks **every address** (95 base58 characters, or 106 for an integrated one) in its pages and
   JSON against the wallet's signed list and an `allowed` file, as written (tags and attributes
   included, entities read as a browser reads them; a character that isn't ASCII read both as
   nothing and as a space), the JSON as JSON (its `\u` escapes read, a key twice both times), and
   **every QR code**: each `data:image/png;base64,` image must be, pixel for pixel, the QR code
   `qrencode -s 10` makes of such an address, as ccs-front-bash makes it (a good QR code with
   something drawn beside it, which zbarimg would read past, is held back). Pages and JSON must
   start as text does (`<`, `[` or `{`): a browser shows an `<img src="x.html">` by its bytes;
4. checks every other file the push changes: it must be the design's, byte for byte
   (`design.sha256`, from the design release: a stylesheet can hide the address and show another,
   an image can be another QR code), a proposal's image (`images/<proposal>/<file>`) that the
   proposals repository has, byte for byte at that path (a proposal is reviewed and merged before
   it is funded, so the backend can't add an image of its own, such as a QR code cut into pieces
   shown side by side, none of which zbarimg reads; any QR code in it of such an address;
   inverted codes too), `projects.json`, or the signed list, its signature and key, the same
   files as installed here;
5. copies staging into the live site, except a file that fails: that one keeps its last good
   copy (a new one stays out), so one bad page doesn't stop the site updating, and the gate never
   rewrites a file. The push then exits 7 (the backend's log shows it, and its ccs-watch still
   checks the live pages; a refused push is 1); which file, and why, is in
   the web server's journal (`journalctl -t ccs-gate`, and `/var/log/ccs-gate.log` if created
   for ccs-data), and goes to IRC (below);
6. refuses the whole push if its own list isn't the one its `.pin` names, or it has no
   `design.sha256`, design release, `markdown.awk` or `proposals.conf`, or no `zbarimg`,
   `qrencode`, `python3` or `git` (it can't check then).

With `/etc/ccs-gate/alert.conf` it also tells IRC itself, once an hour per address or file: the
one alarm that still sounds when the backend is the one lying.

```
[CCS-watch] the web server held back a page: donation address 9yQXrj…4Kd2 is not in the signed list (its last good copy stays) @ https://<site>/proposals/<page>
[CCS-watch] the web server held back a file: not a page of the design as ccs-front-bash fills it (it differs at character 4916: …) @ https://<site>/funding-required/index.html
[CCS-watch] the web server refuses every push: its signed list isn't the one its .pin names
```

Between pushes only the heartbeat's timer runs (below). Set it up once, as root:

```
apt install zbar-tools qrencode git                                  # the QR codes, read and remade; git, for the proposals
install -m 755 contrib/ccs-receive /usr/local/bin/ccs-receive        # from this repository
install -d -o ccs-data -m 755 /var/lib/ccs-staging
install -d -m 755 /etc/ccs-gate /etc/ccs-gate/design
install -o ccs-data -m 644 /dev/null /var/log/ccs-gate.log          # optional: the refusals, as a file
install -d -o ccs-data -m 755 /var/lib/ccs-gate                      # one push at a time, the last push (the heartbeat), when it last alerted, the proposals fetched
install -m 640 -g ccs-data /dev/null /etc/ccs-gate/alert.conf        # optional: the bot (as ccs-watch's, plain text POST)
printf 'ALERT_URL=http://<bot>:8086/<path>\nSITE_URL=https://<site>\n' > /etc/ccs-gate/alert.conf
# the signed list, its pin, signature and key (ccs-front-bash, setup step 5); its view key file too, if the backend has one
install -m 644 subaddresses.txt subaddresses.txt.pin subaddresses.txt.asc subaddresses.txt.key.asc subaddresses.txt.viewkey /etc/ccs-gate/
cat > /etc/ccs-gate/allowed <<'LIST'                                # other addresses allowed on the site, one a line
888tNkZrPN6JsEgekjMnABU4TBzc2Dt29EPAvkRxbANsAnjyPbb3iQ1YBRk1UXcdRsiKc9dhwMVgN5S9cQUiyoogDavup3H  # the General Fund
LIST
# the proposals repository the backend reads (its checkout's origin), and its branch; LINK_HOSTS:
# other hosts a proposal's link may go to (an older forge its merge requests were on)
printf 'PROPOSALS_GIT=https://repo.getmonero.org/monero-project/ccs-proposals.git\nPROPOSALS_BRANCH=master\n' > /etc/ccs-gate/proposals.conf
# the markdown.awk of the ccs-front-bash release the backend runs (its lib/markdown.awk)
install -m 644 <ccs-front-bash checkout at that tag>/lib/markdown.awk /etc/ccs-gate/markdown.awk
```

They are the same files as on the backend (`/etc/ccs-front/`); `gpg --verify` the list there
first, with the key whose fingerprint ccs-front-hugo's README publishes. `ccs-receive` refuses
every push while the list isn't the one its `.pin` names.

**The design**, the release zip the backend runs (its sha256 checked, as on the backend:
ccs-front-bash's setup step 1): unpacked, and the sums of every file but the pages:

```
v=v0.1.16
sha256sum ccs-front-hugo-$v.zip                                      # the attested one
unzip -q ccs-front-hugo-$v.zip -d /etc/ccs-gate/design/$v
(cd /etc/ccs-gate/design/$v && find . -type f ! -name '*.html' -exec sha256sum {} +) > /etc/ccs-gate/design.sha256
```

A new design release: unpack it beside the old one and **add** its lines (`>>`) to
`design.sha256` before the backend switches to it, so both are allowed while it does; the old
folder and lines can go once the new design is live. A new ccs-front-bash release whose
`markdown.awk` changed: install it as a second file (`markdown-<release>.awk`) first, the same
way. Then the push key's `command="rrsync -wo -no-del -munge /var/lib/ccs-data"` becomes
`command="/usr/local/bin/ccs-receive"`; empty `/var/lib/ccs-data` first if anything was pushed
before (the gate trusts what is already live, and nothing can delete it).

A proposal whose text quotes some other address stops its page updating until you add that
address to `allowed` (the refusal names it): the safe way to fail. On the testnet that was two
(`utxobr-monero-k8s-operator`, `el00ruobuob-oct-dec-2018`). A new list: install its four files
the same way. `tests/gate.sh` builds this in containers, with a small design in the release
zip's shape: a good push goes live; a page changed anywhere the design doesn't fill, an address
split by markup, an invisible image's alt text, a `<br>`, a class or a zero-width space, padded
by a no-break space, an entity in an address, another proposal text than the repository's, text
the design's classes could hide, a `style` attribute, an `<svg>`, a QR code drawn as text, a link
to another site, a `monero:` link with more than an address, a foreign address in the donation
box, a QR code of another address or not exactly qrencode's (another size, more drawn beside
it), a `\u` escape or a key twice in `projects.json`, a page the design doesn't have, a page
named with a backslash or wildcard, a PNG named `.html` or `projects.json`, a NUL byte, a
stylesheet or design file that isn't the design's, a swapped list, a proposal image that is
another QR code, inverted or not, or that the repository doesn't have (or has at another path,
or other bytes) are held back and the live file kept; ideas titled with "data:", "charset=",
`▶` or `🟢` go live; the repository down, the last fetch is used; two pushes at once go one
after the other; the next good push goes through; no design or `markdown.awk`, or a list that
isn't the pinned one, refuses everything; no deleting and nothing outside the folder, as with
rrsync alone.

**What it can't see:** what only the backend knows, in the shape it has: a total, a count or a
percentage that is wrong but a number, an idea that is no merge request (its title still
escaped text, its link still to the forge), one of the wallet's own subaddresses on another
proposal's page (the money stays in the CCS wallet). ccs-watch (below) and visitors comparing
what their wallet shows are what catch a web server that lies; the forge's own pages, an idea
list that lies. zbarimg reads images the backend sends, as ccs-data: keep zbar-tools (and the
ImageMagick it uses) updated (`unattended-upgrades`).

It can't help if the web server itself is taken over (whoever has it can turn the gate off):
there, ccs-watch and visitors checking an address against the signed list are the defence.

### The heartbeat: the web server notices a silent backend

Every alert the backend sends runs on the backend, so a backend that is off, whose cron stopped,
or whose key or network broke, says nothing. Its pushes, one every run (2 minutes), are its
heartbeat: the gate notes each one that arrives, and a timer on the web server, every 5 minutes,
alerts when none has for 15 minutes (`HEARTBEAT_MINUTES` in `alert.conf` to change it). To keep
false alarms out, it stays quiet

- before the first push (nothing is known yet);
- while the web server itself has been up less than that (no push could arrive while it was down);
- on the first late check: only the second in a row alerts, so pushes resuming after the web
  server's own network outage come first.

Then once an hour at most, and one line when pushes arrive again:

```
[CCS-watch] no push from the backend for 17 minutes: is it running? (its cron, its push key, its network) @ https://<site>
[CCS-watch] pushes from the backend arrive again @ https://<site>
```

It is `ccs-receive --heartbeat`, run as ccs-data (the backend's key can't pass it arguments:
its `command=` is fixed). As root:

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

`tests/gate.sh` checks it: no alert after a recent push, none on the first late check, one on the
second, not again within the hour, a line when pushes return, and none before any push.

## Watching the web server (way A): the backend raises the alarm

The gate can't help if the web server itself is taken over. `contrib/ccs-watch`, run on the
backend right after each push, fetches the pages where donations are asked for (home, Funding
Required, Donate, Verify, every funding-required proposal) from the site as a visitor's browser
would, and every file they use (the stylesheets with `theme.css`, the fonts, the icons, the General
Fund's QR code, the proposals' images: a changed stylesheet can hide an address and show another
while the page stays the same), and `WATCH_SAMPLE` (10) of the other pages at random, so that
every page is seen within a few runs (a web server could add a donation box to any page), and
`/projects`, and compares each, byte for byte, with what was just pushed. A difference is an
alert, naming the page or file and any address on the page that isn't on the signed list; so is
a page that answers anything but the page (a redirect elsewhere, an error, nothing) on three
checks in a row while the rest of the site answers. (A push doesn't fix such a file by itself:
rsync skips a file whose size and time were kept.)

So that the web server can't serve it the right pages and visitors others, it asks as Tor Browser
asks (its user agent and the headers Firefox 128 sends: `Sec-Fetch-*` for a page as a page and a
stylesheet as one, `Upgrade-Insecure-Requests`, its compression), in no fixed order, each page under `/`, `/dark/` or
`/light/` at random (`WATCH_THEMES=1`, with the theme lines above), through a proxy picked at
random for each fetch. Tor alone isn't enough: its exits are a public list a web server can check.
Give it Tor and a clearnet one on another network (`ssh -D 1080 <a machine elsewhere>`, kept up by
a service, then `socks5h://127.0.0.1:1080`), and if you can, run a second ccs-watch on another
machine with a copy of the site.

The alert goes to one URL, POSTed as plain text: an IRC bot (CptHook's `simple` module:
`https://<host>/<endpoint>?channel=%23<channel>`), ntfy (`https://ntfy.sh/<a long random topic>`),
or anything else that takes a POST; or, with `ALERT_TARGET` and `ALERT_PASSWORD` set, as wmb's
`/directedMessage` JSON (the bot must be in that channel: Libera won't take it from outside).
`ccs-watch --test https://<the site>` sends one message to check it. It lives in a file only root and ccs read, in no repository:

```
install -m 640 -g ccs /dev/null /etc/ccs/alert.conf
cat > /etc/ccs/alert.conf <<'CONF'
ALERT_URL=https://<the bot>/simple?channel=%23<channel>
SUBADDRESSES=/etc/ccs-front/subaddresses.txt        # to name addresses not on the list
WATCH_PROXY=socks5h://127.0.0.1:9050 socks5h://127.0.0.1:1080   # one at random a fetch: Tor (apt install tor), and a clearnet one elsewhere
WATCH_THEMES=1                                      # also /dark/ and /light/ (the theme lines above)
WATCH_SAMPLE=10                                     # other pages, at random, each run
CONF
```

and `ccs-bash-update` runs it after the push (also after one the gate held a file of back, exit
7: a web server that lies can't hide behind a held-back page), then tells it how the whole run went
(`ccs-watch --run`, the last line in [the handover](handover.md#9-the-update)), so that a backend which
has stopped (an image gone, the wallet down, the push refused) is an alarm too: the page check
only runs after a good push, and a stale site still matches what was last pushed.

One alert per problem an hour while it lasts; "could not be fetched" after three checks in a row;
"the backend has failed N runs in a row since …: <steps>" after three failed runs (about six
minutes), and "the backend runs again" on the first good run after that.
A careful attacker on the web server can still tell the watcher from visitors: its TLS handshake
is curl's, not Firefox's, and it comes every two minutes after a push. The proxies and a second
watcher elsewhere make that harder, not impossible (a real browser, headless Tor Browser, would
close the first), which is why the Verify page asks visitors to check the address their wallet
shows.
`tests/watch.sh` runs it against a local web server and a fake bot.

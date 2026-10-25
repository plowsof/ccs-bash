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
server refuse any with an address that isn't the wallet's ([Security](../README.md#security)).

## The gate (way A, recommended): the web server checks every address

The web server's last check, so a bad address has to get past two machines: `contrib/ccs-receive`,
a bash script, run by the push key instead of rrsync. Each push, one at a time, it

1. makes a staging folder a copy of the live site, and receives the push into it (rrsync, with
   the same `-wo -no-del -munge`);
2. checks every address (95 base58 characters, or 106 for an integrated one) in its pages and
   JSON against the wallet's signed list and an `allowed` file, read four ways, so that it can't
   be slipped past by how it is written:
   - **as written**, attributes included (`monero:` links, `alt`, `title`), with entities read
     as a browser reads them (`&#56;` and `&#x38;` are `8`), and %-escapes in a `monero:` link as
     a wallet reads them (`%38` is `8`; in a page's text a browser shows them as they are);
   - **as shown**: comments and tags removed as a browser reads them (a `>` quoted in a tag, a
     comment up to its `-->`), so an address split by `<span></span>`, `<wbr>` or a comment is
     one again, while a block tag (`<p>`, `<div>`, `<br>`, `<td>`...) is a space, its text on a
     line or in a cell of its own; an image's alt text where it stands (a broken image shows it
     inline);
   - **the design's hidden text**: an element with a class its stylesheets hide something with
     (`hidden-classes`, below) may be hidden or not, each on its own: by the screen's width, a
     box ticked, the theme, being empty, and two may take turns (*Menu*, *Close*). A run of
     letters and digits a visitor would see only with one hidden, 95 or more, joined across the
     gap or cut short by it, is held back: it could be an address the text as shown doesn't
     hold. Where a browser may end such an element before its end tag (an end tag out of order,
     an `<a>` in an `<a>`), it counts as two there, each hidden or not;
   - with every character that isn't ASCII dropped first (zero-width spaces, bidi marks, soft
     hyphens: invisible, so they mustn't split an address), as text or as an entity;
   - **every QR code**: each `data:` URI in a page must be written exactly
     `data:image/png;base64,` (no tab or space in its scheme, which a browser would take out),
     and be, pixel for pixel, the QR code `qrencode -s 10`
     makes of such an address, as ccs-front-bash makes it (the box's text right and its QR code
     another's is held back; so is a good QR code with something drawn beside it, which zbarimg
     would read past);
   - pages and JSON must start as text does (`<`, `[` or `{`): a browser shows an
     `<img src="x.html">` by its bytes, so an image named as a page would otherwise go unread;
   - **its places**: a `monero:` URL, in any attribute, has one address straight after it and
     nothing else, read with tabs and spaces taken out (a browser takes tabs and newlines out of
     a URL), an address box (`class="address"`) one address and no markup;
   - an entity without its `;` (a browser reads `&shy` as a soft hyphen), a NUL byte (dropped
     from the text) and a charset other than UTF-8 are refused;
   - and no markup that hides, moves or colours without a stylesheet, which the design never
     uses: `hidden`, `dir`, `style` or `popover` attributes, `<svg>`, `<template>`, `<bdo>`,
     `<ruby>`..., `<font>`, `<mark>`, the colour, border and size attributes (`bgcolor`,
     `border`, `width` but on an `<img>`...), and no `http-equiv` but the design's
     `refresh` of the page itself (no URL); at most 64 images, bars and boxes a page (a QR code
     drawn with one a module takes hundreds; the most any page has is 13);
   - and no characters that can draw a QR code as text, as characters or entities: block
     elements and geometric shapes (`█▀▄■□▪`, U+2580–25FF), braille (U+2800–28FF), the big
     squares and circles (`⬛⬜⚫⚪🔲🔳`), the coloured ones (`🟥🟩`..., U+1F7E0–1F7EB) and the
     block mosaics of U+1FB00–1FBFF. No proposal uses them;
3. checks every other file the push changes: it must be the design's, byte for byte
   (`design.sha256`, from the design release: a stylesheet can hide the address and show
   another, an image can be another QR code), a proposal's image (`images/<proposal>/<file>`)
   that the proposals repository has, byte for byte at that path (fetched each push, below: a
   proposal is reviewed and merged before it is funded, so the backend can't add an image of its
   own, such as a QR code cut into pieces shown side by side, none of which zbarimg reads; any QR
   code in it of such an address; inverted codes too), `projects.json`, or the signed list, its signature and key,
   the same files as installed here. While the repository can't be fetched, a new image waits
   (its page goes live without it);
4. copies staging into the live site, except a file that fails: that one keeps its last good
   copy (a new one stays out), so one bad page doesn't stop the site updating, and the gate never
   rewrites a file. The push then fails (the backend's log shows it); which file, and why, is in
   the web server's journal (`journalctl -t ccs-gate`, and `/var/log/ccs-gate.log` if created
   for ccs-data), and goes to IRC (below);
5. refuses the whole push if its own list isn't the one its `.pin` names, or it has no
   `design.sha256` or `hidden-classes`, or no `zbarimg`, `qrencode`, `python3` or `git` (it
   can't check then).

With `/etc/ccs-gate/alert.conf` it also tells IRC itself, once an hour per address or file: the
one alarm that still sounds when the backend is the one lying.

```
[CCS-watch] the web server held back a page: donation address 9yQXrj…4Kd2 is not in the signed list (its last good copy stays) @ https://<site>/proposals/<page>
[CCS-watch] the web server held back a file: not the design's (design.sha256) (its last good copy stays) @ https://<site>/assets/theme.css
[CCS-watch] the web server refuses every push: its signed list isn't the one its .pin names
```

Between pushes only the heartbeat's timer runs (below). Set it up once, as root:

```
apt install zbar-tools qrencode git                                  # the QR codes, read and remade; git, for the proposals' images
install -m 755 contrib/ccs-receive /usr/local/bin/ccs-receive        # from this repository
install -d -o ccs-data -m 755 /var/lib/ccs-staging
install -d -m 755 /etc/ccs-gate
install -o ccs-data -m 644 /dev/null /var/log/ccs-gate.log          # optional: the refusals, as a file
install -d -o ccs-data -m 755 /var/lib/ccs-gate                      # one push at a time, the last push (the heartbeat), when it last alerted
install -m 640 -g ccs-data /dev/null /etc/ccs-gate/alert.conf        # optional: the bot (as ccs-watch's, plain text POST)
printf 'ALERT_URL=http://<bot>:8086/<path>\nSITE_URL=https://<site>\n' > /etc/ccs-gate/alert.conf
# the signed list, its pin, signature and key (ccs-front-bash, setup step 5)
install -m 644 subaddresses.txt subaddresses.txt.pin subaddresses.txt.asc subaddresses.txt.key.asc /etc/ccs-gate/
cat > /etc/ccs-gate/allowed <<'LIST'                                # other addresses allowed on the site, one a line
888tNkZrPN6JsEgekjMnABU4TBzc2Dt29EPAvkRxbANsAnjyPbb3iQ1YBRk1UXcdRsiKc9dhwMVgN5S9cQUiyoogDavup3H  # the General Fund
LIST
# the proposals repository the backend reads (its checkout's origin), and its branch
printf 'PROPOSALS_GIT=https://repo.getmonero.org/monero-project/ccs-proposals.git\nPROPOSALS_BRANCH=master\n' > /etc/ccs-gate/proposals.conf
```

They are the same files as on the backend (`/etc/ccs-front/`); `gpg --verify` the list there
first, with the key whose fingerprint ccs-front-hugo's README publishes. `ccs-receive` refuses
every push while the list isn't the one its `.pin` names.

**The design's files**, from the release zip the backend runs (its sha256 checked, as on the
backend: ccs-front-bash's setup step 1), every file but the pages:

```
v=v0.1.13
sha256sum ccs-front-hugo-$v.zip                                      # the attested one
unzip -q ccs-front-hugo-$v.zip -d /tmp/design-$v
(cd /tmp/design-$v && find . -type f ! -name '*.html' -exec sha256sum {} +) > /etc/ccs-gate/design.sha256
cp /tmp/design-$v/assets/hidden-classes.txt /etc/ccs-gate/hidden-classes   # the classes it hides text with
```

A new design release: **add** its lines (`>>`) to both files before the backend switches to
it, so both are allowed while it does; old lines can go once the new design is live. Then the push key's
`command="rrsync -wo -no-del -munge /var/lib/ccs-data"` becomes `command="/usr/local/bin/ccs-receive"`.

A proposal whose text quotes some other address stops its page updating until you add that
address to `allowed` (the refusal names it): the safe way to fail. On the testnet that was two
(`utxobr-monero-k8s-operator`, `el00ruobuob-oct-dec-2018`). A new list: install its four files
the same way. `tests/gate.sh` builds this in containers: a good push goes live; a foreign
address, in the donation box or anywhere in a page, split by markup, a comment, hidden text, a
zero-width space, a bidi mark or an entity, %-escaped in a `monero:` link, integrated, behind
`data:`, or only in the QR code, is held back and the live file kept; so is a page with a
backslash or wildcard in its name, a `dir` attribute or an `<svg>`, a data: image that isn't a QR
code, a stylesheet or design file that isn't the design's, a swapped list, a proposal image that
is another QR code, inverted or not, a `data:` image that isn't exactly qrencode's QR code (another
size, an extra chunk, a good one with more drawn beside it), a PNG named `.html` or
`projects.json`, block, square, braille or mosaic characters, a NUL byte, `&shy` without its
`;`, a `monero:` URL split by tabs or newlines, alt text beside the rest of an address, an address
split by text the design's classes hide or whole only with one hidden, a
charset that isn't UTF-8, a refresh to another site, `<font color>`, `bgcolor`, 65 images, a proposal image the
repository doesn't have (or has at another path, or other bytes), and a new one while the
repository can't be fetched; two pushes at once go one after the other; the next good
push goes through; a list that isn't the pinned one refuses everything; no deleting and nothing
outside the folder, as with rrsync alone.

**What it can't see:** a QR code drawn with elements the design's own stylesheet colours
(inline `<code>`, tag pills); a QR code drawn as text with characters it doesn't refuse (ASCII
art, other emoji), which phones read badly at a page's line spacing; and a link to another
site. Checking pages against the design's own pages, outside the regions it fills, would close
the first.
ccs-watch (below) and visitors comparing what their wallet shows are what catch those. zbarimg reads images the backend sends, as ccs-data: keep zbar-tools (and the
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
while the page stays the same), and compares each, byte for byte, with what was just pushed. A
difference is an alert, naming the page or file and any address on the page that isn't on the
signed list. (A push doesn't fix such a file by itself: rsync skips a file whose size and time
were kept.)

So that the web server can't serve it the right pages and visitors others, it asks as Tor Browser
asks (its user agent, headers, compression), in no fixed order, each page under `/`, `/dark/` or
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
CONF
```

and `ccs-bash-update` runs it after the push, then tells it how the whole run went
(`ccs-watch --run`, the last line in [the handover](handover.md#9-the-update)), so that a backend which
has stopped (an image gone, the wallet down, the push refused) is an alarm too: the page check
only runs after a good push, and a stale site still matches what was last pushed.

One alert per problem an hour while it lasts; "could not be fetched" after three checks in a row;
"the backend has failed N runs in a row since …: <steps>" after three failed runs (about six
minutes), and "the backend runs again" on the first good run after that.
A careful attacker on the web server can still try to tell the watcher from visitors (its timing,
every two minutes after a push): the proxies and a second watcher elsewhere make that harder, not
impossible, which is why the Verify page asks visitors to check the address their wallet shows.
`tests/watch.sh` runs it against a local web server and a fake bot.

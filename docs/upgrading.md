# Upgrading

Steps a release needs **once**, on top of [deploying a set](deploying.md).
Newest first. Upgrading across several releases: do each step listed between the running release
and the new one, oldest first. A release not listed needs none.

## ccs-bash v0.2.55: the push is site-data.json as it is, not a tar

The backend sends `site-data.json` as it is on ssh's stdin (nothing for the heartbeat), not a tar
of it; the gate takes that one file. The new gate still takes an older backend's heartbeat (its
empty tar) but refuses its tar of data; the old gate refuses the new backend's file. So **the web
server first, then the backend at once**: until the backend's turn, a push with new data is
refused (`the web server refused a push it could not take: not site-data.json`, alerted once),
and the next push after it sends it again. The new backend also counts a push as taken only when
the gate says so (`took <sha256>`, which only the new gate says: review 12's I-3), so with the old
gate every run's push would fail. Nothing else to do.

## ccs-bash v0.2.53: the backend sends only site-data.json; the web server builds the site

The backend no longer runs ccs-front-bash (no `front` service) and pushes `site-data.json` alone;
the web server's gate builds the site from it every time, with the signed list's QR codes
installed there, and refuses a push with any other file. ccs-watch checks the live pages'
addresses instead of comparing them with a pushed copy.

**This once, the backend goes first:** the old gate takes a push of `site-data.json` alone (it
builds the site from it, as v0.2.52 does), the new one refuses the old backend's pages.

1. **The web server, prepared** (nothing restarts): the list's QR codes beside the list, from the
   backend's `/etc/ccs-front/subaddresses.txt.qr/`, checked against their pinned sums; and each
   proposal's merge request link read from the repository's merge commits:
   ```
   install -d -m 755 /etc/ccs-gate/subaddresses.txt.qr && install -m 644 <the list's>/subaddresses.txt.qr/*.png /etc/ccs-gate/subaddresses.txt.qr/
   (cd /etc/ccs-gate/subaddresses.txt.qr && sha256sum -c --quiet ../subaddresses.txt.qr.sha256)
   cp -a /etc/ccs-gate/proposals.conf "$B/" && echo 'MERGE_REQUESTS=https://repo.getmonero.org' >> /etc/ccs-gate/proposals.conf
   ```
2. **The backend** (its step 4), with the compose's old `front` container taken down and its
   settings out of `.env`:
   ```
   sed -i '/^CCS_FRONT_IMAGE=/d; /^FRONT_UID=/d; /^#\?CCS_ONION=/d' "$D/.env"
   cd "$D" && docker compose config -q && docker compose up -d --remove-orphans
   ```
   In alert.conf, `WATCH_ALLOWED`: every address in the web server's `allowed`, space-separated
   (none set: the General Fund alone). The next push is `site-data.json` (`ccs status`: the push
   `pushed`), and the old gate builds the site from it.
3. **The web server's gate** (its step 3b). Its first push builds the site: `built the site from
   site-data.json (…): live`. Then what it no longer reads can go:
   ```
   rm -f /etc/ccs-gate/markdown*.awk /etc/ccs-gate/design.sha256*
   rm -rf /var/lib/ccs-gate/bodies-* /var/lib/ccs-gate/fronts-* /var/lib/ccs-gate/held /var/lib/ccs-gate/checked-with /var/lib/ccs-gate/quarantine
   ```
4. **The backend, after:** what only `front` and the pushed copy used:
   `rm -rf /var/lib/ccs/www /var/lib/ccs/pushed /var/lib/ccs/run/front /opt/ccs-front-hugo` and
   `userdel ccs-front`; ccs-front-bash's keep container and image (`docker rm ccs-front-bash-keep-<release>`).

Going back: the old backend's `.env` and checkout (its `front` comes back with `docker compose
up -d`), then the old gate; the files above, from `$B` and the releases, if already removed.

## ccs-bash v0.2.45: the site served from the gate's image (Caddy and Tor, not the host's nginx)

The web server compose's `www` (Caddy) and `tor` take over from the host's nginx, certbot and the
onion lines of the host's Tor ([two machines](two-machines.md), "The site: Caddy and Tor"). On the
web server, as root, before its step 3 (`B` the backup folder):

```
for u in ccs-www ccs-tor; do useradd --system --no-create-home --shell /usr/sbin/nologin $u; done
install -d -o ccs-www -m 755 /var/lib/ccs-www /var/lib/ccs-www/onion /var/lib/ccs-www/sites
install -d -o ccs-www -m 700 /var/lib/ccs-www/data
install -d -o ccs-tor -m 700 /var/lib/ccs-tor
# the onion keeps its address: its keys, from the host's Tor (where its torrc's HiddenServiceDir says)
cp -a /var/lib/tor/hidden_service/ccs "$B/onion-keys"
cp -a /var/lib/tor/hidden_service/ccs /var/lib/ccs-tor/ccs && chown -R ccs-tor: /var/lib/ccs-tor && chmod 700 /var/lib/ccs-tor/ccs
```

In the compose's `.env`: `CCS_WWW_UID`, `CCS_TOR_UID` (`id -u ccs-www`:`id -g ccs-www`...),
`CCS_SITE_HOST`, `CCS_ONION` (`/var/lib/ccs-tor/ccs/hostname`) and `CCS_ACME_EMAIL`. Then the
switch, a minute without the site: the host's nginx stops (Caddy needs 80 and 443), the
compose starts both, Caddy gets its certificate at once:

```
cp -a /etc/nginx "$B/" && systemctl disable --now nginx
docker compose up -d www tor && docker compose ps www tor          # healthy
curl -sSI https://<the site>/ | head -n 3                          # 200, its headers
```

The onion: once it answers through the compose's `tor` (Tor Browser, or `ccs-watch`), take the
`HiddenServiceDir .../ccs` and its `HiddenServicePort` out of the host's torrc and reload its Tor
(a machine without other onions: `systemctl disable --now tor`); certbot's certificate for the
site: `certbot delete --cert-name <the site>` (a machine without other certificates: remove
certbot). A site of the machine's own that nginx served (another host's ACME challenges, say): a
`/var/lib/ccs-www/sites/<name>.caddy`. Back: `docker compose stop www tor`, `systemctl enable
--now nginx`, the host torrc's lines again.

## ccs-bash v0.2.41 (2026-11-02): the push is a tar

`contrib/ccs-push` and the gate's `ccs-check receive`; no rsync on either machine. The new gate
refuses the old backend's rsync push, and the old gate the new backend's tar, so pushes fail from
step 3 until step 5 (the live site stays as it is; past 15 minutes the heartbeat tells IRC, then
that they arrive again). Do the backend right after the web server. The first push sends every
file (no record yet of what the gate took).

## ccs-bash v0.2.41 and ccs-front-bash v0.1.26 (2026-11-02): the QR codes are the list's files

The list's QR codes, made from the list with `tools/make-qr.sh` from ccs-front-bash's attested
commit, on a computer you trust with qrencode (the signer's offline machine, or your own; not the
backend, which could print OK over a list it swapped), then checked with the `.pin` from this
repository's `subaddresses/<wallet>/` (the same list, a third line `qr …`;
[the signed list](signed-list.md)):

```
git clone -q https://github.com/plowsof/ccs-front-bash && git -C ccs-front-bash checkout -q <its attested commit>
git clone -q https://github.com/plowsof/ccs-bash && git -C ccs-bash checkout -q <its attested commit>
install -d -m 700 l && cp ccs-bash/subaddresses/<wallet>/subaddresses.txt* l/
ccs-front-bash/tools/make-qr.sh l/subaddresses.txt                    # .qr/ and .qr.sha256, about 30 s
SIGNER_KEYS=<the signer's key> ccs-front-bash/tools/verify-subaddresses.sh l/subaddresses.txt <your list-signers> <WALLET_ADDRESS>
```

OK: the new `.pin` and `.qr.sha256` go to `/etc/ccs-front/` and `/etc/ccs-gate/` (root, 644),
`subaddresses.txt.qr/` to `/etc/ccs-front/` only (755); copy each file into place, the pin last
(the old releases ignore the `qr` line and the new files). Without them the new gate refuses every
push and the new ccs-front-bash stops. Then the web server's headers: `img-src 'self'` (no `data:`,
[two machines](two-machines.md)), once the backend's new release is live.

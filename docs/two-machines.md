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
install -d -m 755 ~ccs-data/.ssh                          # root-owned: the account can't change its key
# ~ccs-data/.ssh/authorized_keys (root, 644):
from="<wallet machine IP>",command="rrsync -wo -no-del -munge /var/lib/ccs-data",restrict ssh-ed25519 AAAA... ccs-bash
```

| If the key is stolen, this stops | |
|---|---|
| `restrict` | shells, forwarding, a terminal |
| `-wo` | reading back, writing outside the folder |
| `-no-del` | deleting |
| `-munge` | symlinks (a `projects.json` link to any file would get nginx to publish it) |
| `from=` | use from another machine |
| root-owned `.ssh` | loosening the key line |
| own filesystem / quota | filling the disk |

Then either of two ways:

**A) With ccs-front-bash** (the site is made on the ccs-bash machine, see [the design](design.md)):
the web server only serves what arrives, nothing else is installed or run there. nginx:

```
server {
    listen 80 default_server;
    root /var/lib/ccs-data;
    disable_symlinks on;
    add_header Content-Security-Policy "default-src 'none'; style-src 'self'; img-src 'self' data:; font-src 'self'" always;
    location = /projects {                          # the site carries projects.json
        alias /var/lib/ccs-data/projects.json;
        default_type application/json;
        add_header Content-Security-Policy "default-src 'none'; style-src 'self'; img-src 'self' data:; font-src 'self'" always;
    }
}
```

(A `location` with its own `add_header` drops the server's, hence the CSP twice.)

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

`ccs-bash-update` (step 6) pushes; `--delay-updates` swaps the files in only once all have
arrived. **A)** push the site ccs-front-bash made:

```
#!/bin/sh
# /usr/local/bin/ccs-bash-update (chmod 755)
timeout -k 5 40 runuser -u ccs-git -- env HOME=/ git -C /var/lib/ccs/proposals pull -q --ff-only
ccs-bash-run >> /var/log/ccs-bash.log 2>&1
runuser -u ccs-front -- /opt/ccs-front-bash/ccs-front-bash.sh \
    /opt/ccs-front-hugo/public /var/lib/ccs/out /var/lib/ccs/proposals /var/lib/ccs/www/site \
    >> /var/log/ccs-bash.log 2>&1 \
&& timeout -k 5 120 runuser -u ccs -- rsync -a --delay-updates \
    -e "ssh -p 22 -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=15" \
    /var/lib/ccs/www/site/ ccs-data@<web server>: >> /var/log/ccs-bash.log 2>&1
```

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
a short bash script, run by the push key instead of rrsync. Each push, it

1. makes a staging folder a copy of the live site, and receives the push into it (rrsync, with
   the same `-wo -no-del -munge`);
2. finds every address-shaped string (95 base58 characters) in its pages and JSON (the QR codes'
   base64 skipped) and checks each against the wallet's signed list and an `allowed` file;
3. copies staging into the live site, except a page with any other address: that one keeps its
   last good copy (a new one stays out), so one bad page doesn't stop the site updating, and the
   gate never rewrites a page. The push then fails (the backend's log shows it); which address,
   in which page, is in the web server's journal (`journalctl -t ccs-gate`, and
   `/var/log/ccs-gate.log` if created for ccs-data), and goes to IRC (below);
4. refuses the whole push if its own list isn't the one its `.pin` names (it can't check then).

With `/etc/ccs-gate/alert.conf` it also tells IRC itself, once an hour per address: the one alarm
that still sounds when the backend is the one lying.

```
[CCS-watch] the web server held back a page: donation address 9yQXrj…4Kd2 is not in the signed list (its last good copy stays) @ https://<site>/proposals/<page>
[CCS-watch] the web server refuses every push: its signed list isn't the one its .pin names
```

Nothing runs between pushes: no daemon, no timer. Set it up once, as root:

```
install -m 755 contrib/ccs-receive /usr/local/bin/ccs-receive        # from this repository
install -d -o ccs-data -m 755 /var/lib/ccs-staging
install -d -m 755 /etc/ccs-gate
install -o ccs-data -m 644 /dev/null /var/log/ccs-gate.log          # optional: the refusals, as a file
install -d -o ccs-data -m 755 /var/lib/ccs-gate                      # optional, with alert.conf: when it last alerted
install -m 640 -g ccs-data /dev/null /etc/ccs-gate/alert.conf        # optional: the bot (as ccs-watch's, plain text POST)
printf 'ALERT_URL=http://<bot>:8086/<path>\nSITE_URL=https://<site>\n' > /etc/ccs-gate/alert.conf
install -m 644 subaddresses.txt subaddresses.txt.pin /etc/ccs-gate/  # the signed list and its pin (ccs-front-bash, setup step 5)
cat > /etc/ccs-gate/allowed <<'LIST'                                # other addresses allowed on the site, one a line
888tNkZrPN6JsEgekjMnABU4TBzc2Dt29EPAvkRxbANsAnjyPbb3iQ1YBRk1UXcdRsiKc9dhwMVgN5S9cQUiyoogDavup3H  # the General Fund
LIST
```

They are the same files as on the backend (`/etc/ccs-front/`); `gpg --verify` the list there
first, with the key whose fingerprint ccs-front-hugo's README publishes. `ccs-receive` refuses
every push while the list isn't the one its `.pin` names. Then the push key's
`command="rrsync -wo -no-del -munge /var/lib/ccs-data"` becomes `command="/usr/local/bin/ccs-receive"`.

A proposal whose text quotes some other address stops the site updating until you add that
address to `allowed` (the refusal names it): the safe way to fail. On the testnet that was two
(`utxobr-monero-k8s-operator`, `el00ruobuob-oct-dec-2018`). A new list: install it and its
`.pin` the same way. `tests/gate.sh` builds this in containers: a good push goes live; a foreign
address, in the donation box or anywhere in a page, is refused and the live site kept; the next
good push goes through; a list that isn't the pinned one refuses everything; no deleting and
nothing outside the folder, as with rrsync alone.

It can't help if the web server itself is taken over (whoever has it can turn the gate off):
there, visitors checking an address against the signed list is the defence.

## Watching the web server (way A): the backend raises the alarm

The gate can't help if the web server itself is taken over. `contrib/ccs-watch`, run on the
backend right after each push, fetches the pages where donations are asked for (home, Funding
Required, Donate, Verify, every funding-required proposal) from the site as a visitor would, and
compares each, byte for byte, with what was just pushed. A difference is an alert, naming the page
and any address on it that isn't on the signed list. (A push doesn't fix such a page by itself:
rsync skips a file whose size and time were kept.) Nine pages took about a second on the testnet.

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
WATCH_PROXY=socks5h://127.0.0.1:9050               # recommended: through Tor (apt install tor), as any visitor
CONF
```

and `ccs-bash-update` runs it after the push, then tells it how the whole run went, so that a
backend which has stopped (an image gone, the wallet down, the push refused) is an alarm too: the
page check only runs after a good push, and a stale site still matches what was last pushed.

```
#!/bin/sh
# /usr/local/bin/ccs-bash-update (chmod 755): as above, each step noted if it fails
L=/var/log/ccs-bash.log W=/opt/ccs-bash/contrib/ccs-watch failed=''
timeout -k 5 40 runuser -u ccs-git -- env HOME=/ git -C /var/lib/ccs/proposals pull -q --ff-only   # GitLab down: give up
ccs-bash-run >> $L 2>&1 || failed="ccs-bash"
if ccs-front-run >> $L 2>&1; then
    if timeout -k 5 120 runuser -u ccs -- rsync -a --delay-updates -e "ssh -o BatchMode=yes" \
            /var/lib/ccs/www/site/ ccs-data@<web server>: >> $L 2>&1; then
        runuser -u ccs -- $W https://<the site> /var/lib/ccs/www/site >> $L 2>&1
    else failed="${failed:+$failed, }the push"; fi
else failed="${failed:+$failed, }ccs-front-bash"; fi
runuser -u ccs -- $W --run "${failed:-ok}" >> $L 2>&1
```

One alert per problem an hour while it lasts; "could not be fetched" after three checks in a row;
"the backend has failed N runs in a row since …: <steps>" after three failed runs (about six
minutes), and "the backend runs again" on the first good run after that.
A careful attacker on the web server could serve the backend's IP the right pages: `WATCH_PROXY`
(Tor) or a second watcher elsewhere (a laptop, another machine) makes that much harder.
`tests/watch.sh` runs it against a local web server and a fake bot.

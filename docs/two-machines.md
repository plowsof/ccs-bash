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

A taken-over wallet machine can still push false JSON, and the web server stays the place to
guard ([Security](../README.md#security)).

# ccs-front on another machine

ccs-bash only needs the proposals repo, GitLab and the wallet; ccs-front only needs the
JSON. Running them apart keeps the wallet machine free of any incoming connection: after
each run it pushes `OUTPUT_DIR` to the web server, and the web server can only receive
those files, into one folder, and never connect back.

On the **web server** (ccs-front), create an account that can only receive the files, with
`rrsync` (shipped with Debian's rsync, 3.2.4 or newer for `-wo`). rrsync is a Python script
and Debian's rsync only suggests Python, so install both: `apt install rsync python3`.

```
useradd --system --create-home --shell /bin/sh ccs-data   # no password; the shell only runs the forced command
install -d -o ccs-data -m 755 /var/lib/ccs-data           # ideally a small filesystem of its own (or a quota)
install -d -m 755 ~ccs-data/.ssh                          # owned by root: the account can't change its own key
# ~ccs-data/.ssh/authorized_keys, owned by root, mode 644, one line with the key from the ccs-bash machine:
from="<wallet machine IP>",command="rrsync -wo -no-del -munge /var/lib/ccs-data",restrict ssh-ed25519 AAAA... ccs-bash
```

What each part stops, if the key or the wallet machine is ever taken over:

| | |
|---|---|
| `restrict` | shells, port forwarding, agent forwarding, a terminal |
| `-wo` | reading anything back, writing outside `/var/lib/ccs-data` |
| `-no-del` | deleting files |
| `-munge` | uploaded symlinks working: without it, a link named `projects.json` pointing at any readable file would get that file published by nginx |
| `from=` | using the key from anywhere but the wallet machine |
| root-owned `.ssh` | the account loosening its own key line |
| own filesystem / quota | filling the web server's disk |

Then, as in [setup](setup.md) steps 4 and 5 but with this folder, use `/var/lib/ccs-data` as ccs-front's
`_data` (and for `/projects`, adding `disable_symlinks on;` to that nginx block).
ccs-front keeps its own checkout of the proposals repo for the proposal pages, and its own cron:

```
*/2 * * * * git -C /opt/ccs-front/proposals pull -q --ff-only ; cd /opt/ccs-front && jekyll build -q
```

On the **ccs-bash machine**, give the `ccs` user a key, trust exactly the web server's host
key (copied from its `/etc/ssh/ssh_host_ed25519_key.pub`, not accepted on first connect),
and push after each run:

```
install -d -o ccs -g ccs -m 700 /var/lib/ccs/.ssh
runuser -u ccs -- ssh-keygen -t ed25519 -N '' -f /var/lib/ccs/.ssh/id_ed25519
echo "<web server> ssh-ed25519 AAAA..." > /var/lib/ccs/.ssh/known_hosts    # the web server's host key
```

`ccs-bash-update` ([setup](setup.md) step 6) then pushes instead of building the site:

```
#!/bin/sh
# /usr/local/bin/ccs-bash-update (chmod 755): one update, pushed to the web server
timeout -k 5 40 git -C /var/lib/ccs/proposals pull -q --ff-only
{ ccs-bash-run && runuser -u ccs -- rsync -a --delay-updates \
    -e "ssh -o BatchMode=yes -o StrictHostKeyChecking=yes" /var/lib/ccs/out/ ccs-data@<web server>: ; } >> /var/log/ccs-bash.log 2>&1
```

`--delay-updates` puts the new files in place only once all of them have arrived. Run it from
cron or `notify-loop.sh`, as in [setup](setup.md) steps 6 and 7.

`tests/rrsync.sh` builds this setup in three containers (web server, wallet machine, another
machine) and tries everything in the table above from the wallet machine's key: commands,
port forwarding, reading back, `..` and absolute paths, `--temp-dir`, `--partial-dir`,
`--backup-dir`, `--log-file`, `--link-dest`, `--copy-dest`, `--compare-dest`, deleting,
symlinks, and the key from another machine. All are refused or stay inside the folder.
With `--loose` (rrsync alone, without the other restrictions) those checks fail, so the test
does catch them.

This can't stop a taken-over wallet machine from pushing false JSON (it is the source of the
data), and the web server stays the place to guard, see [Security](../README.md#security).

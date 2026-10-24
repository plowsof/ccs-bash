# Deploying the CCS: start here

The Monero CCS website is made by three repositories. This page is the order to set them up in,
and the one script that runs them; each step's details are in the repository it belongs to.

| Repository | What it is | Runs on |
|---|---|---|
| [ccs-bash](https://github.com/plowsof/ccs-bash) (this one) | the backend: proposals, the wallet, totals, addresses, as JSON | the backend |
| [ccs-front-bash](https://github.com/plowsof/ccs-front-bash) | the site builder: fills the design with ccs-bash's data, every page, in bash | the backend |
| [ccs-front-hugo](https://github.com/plowsof/ccs-front-hugo) | the design: the site's HTML and CSS, built once with Hugo, released as a zip | nowhere live (built offline, or downloaded) |

Why it is split this way, and what each machine may do: [the design](design.md).

## In order

| # | Where | What | Instructions |
|---|---|---|---|
| 1 | offline machine | the signed subaddress list (the wallet's view key, never online) | ccs-front-bash docs/setup.md, step 5 |
| 2 | backend | the wallet, the `ccs` user, the proposals checkout (GitLab or Forgejo), `ccs-bash-run` | [setup](setup.md), steps 1–3 |
| 3 | backend | the design: ccs-front-hugo's release zip, sha256 checked | ccs-front-bash docs/setup.md, step 1 |
| 4 | backend | ccs-front-bash, `ccs-front-run`, with the list from step 1 | ccs-front-bash docs/setup.md, steps 2 and 5 |
| 5 | web server | the push account, the gate (the list and its `.pin` again, by hand), nginx | [two machines](two-machines.md), way A and "The gate" |
| 6 | backup machine | the account that keeps every version of the state | [setup](setup.md#backing-up-the-state) |
| 7 | backend | the alerts (`/etc/ccs/alert.conf`) | [two machines](two-machines.md#watching-the-web-server-way-a-the-backend-raises-the-alarm) |
| 8 | backend | `ccs-bash-update` (below), every 2 minutes and on each new donation | [setup](setup.md), steps 6–7 |

The list is copied by hand to both machines that check it (4 and 5), never pushed by the backend:
a taken-over backend can't swap it. Only step 1 needs the offline machine; the zip in step 3 is
checked by its sha256, and anyone can rebuild it from the tag to the same sum.

## The update

One run of everything, as root (it only starts each step as that step's own user). This is the
only full copy of it; the other pages show the line their step adds.

```
#!/bin/sh
# /usr/local/bin/ccs-bash-update (chmod 755)
L=/var/log/ccs-bash.log W=/opt/ccs-bash/contrib/ccs-watch failed=''

# the proposals; GitLab or Forgejo down: give up, not a failed run (the last checkout stays)
timeout -k 5 40 runuser -u ccs-git -- env HOME=/ git -C /var/lib/ccs/proposals pull -q --ff-only

# ccs-bash: totals, addresses, the JSON
ccs-bash-run >> $L 2>&1 || failed="ccs-bash"

# the state, to the backup machine when it changed (it keeps every version)
sum=$(sha256sum /var/lib/ccs/state/proposals.csv | cut -c1-64)
if [ "$sum" != "$(cat /var/lib/ccs/backup-sent 2>/dev/null)" ] \
    && timeout -k 5 30 ssh -T -i /root/.ssh/ccs-backup_ed25519 -o BatchMode=yes -o IdentitiesOnly=yes \
        -o ConnectTimeout=15 ccs-backup@<backup machine> < /var/lib/ccs/state/proposals.csv >> $L 2>&1; then
    echo "$sum" > /var/lib/ccs/backup-sent
fi

# ccs-front-bash makes the site; it goes to the web server, which must then serve exactly that
if ccs-front-run >> $L 2>&1; then
    if timeout -k 5 120 runuser -u ccs -- rsync -a --delay-updates \
            -e "ssh -p 22 -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=15" \
            /var/lib/ccs/www/site/ ccs-data@<web server>: >> $L 2>&1; then
        runuser -u ccs -- $W https://<the site> /var/lib/ccs/www/site >> $L 2>&1
    else failed="${failed:+$failed, }the push"; fi
else failed="${failed:+$failed, }ccs-front-bash"; fi

# how the run went: three failed runs in a row alert, so a stopped backend can't go unnoticed
runuser -u ccs -- $W --run "${failed:-ok}" >> $L 2>&1
```

| Part | Set up in | Without it |
|---|---|---|
| the pull | [setup](setup.md) step 2 | |
| `ccs-bash-run` | [setup](setup.md) step 3 | |
| the backup | [setup](setup.md#backing-up-the-state) | drop the block; back up `proposals.csv` some other way |
| `ccs-front-run` | ccs-front-bash docs/setup.md, step 2 | |
| the push | [two machines](two-machines.md), way A | one machine: drop it and the page check, nginx serves `/var/lib/ccs/www/site` (ccs-front-bash docs/setup.md, step 4) |
| `ccs-watch` | [two machines](two-machines.md#watching-the-web-server-way-a-the-backend-raises-the-alarm) | without `/etc/ccs/alert.conf` it only logs |

`-p 22` is the web server's ssh port, given in full in case this machine's `ssh_config` defaults
to another. With Jekyll (the old ccs-front) instead of ccs-front-bash, the update is different:
[setup](setup.md) step 6 and [two machines](two-machines.md), way B.

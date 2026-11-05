# Deploying a release

**When:** a release of ccs-bash, ccs-front-bash or ccs-front-hugo has been attested in
[ccs-sigs](https://github.com/plowsof/ccs-sigs) ([releasing](releasing.md)) and should run on the
machines. Nothing changes on a machine until you do this.

The set is the three releases together, as ccs-sigs names it, e.g.
`ccs-bash-v0.2.47+ccs-front-bash-v0.1.27+ccs-front-hugo-v0.1.29`. Below, `SET` is that name, and
`IDB`, `IDG`, `IDF` and `ZIP` are what `verify` prints for it:
- `IDB`: ccs-bash's image ID;
- `IDG`: the gate's;
- `IDF`: ccs-front-bash's;
- `ZIP`: the design zip's sha256.

**The backend stays running.** The web server goes first, because its gate accepts pages of the
old and new release alike. The backend is switched between two runs. Don't stop it: the
web server's heartbeat alerts after 15 minutes without a push.

## What to do for what changed

| Changed | Web server | Backend |
|---|---|---|
| the design only (ccs-front-hugo) | steps 1, 3a | steps 1, 4a, 5a |
| ccs-front-bash only | — | steps 1, 2 (its image), 4, 5 |
| ccs-bash (any code: the gate, the backend, or both) | steps 1, 2, 3b | steps 1, 2, 4, 5 |
| a new `{{slot}}` (design and front-bash together) | the gate first (3b), then 3a | then 4, 5 together |

Before a ccs-bash release, read [upgrading](upgrading.md) for anything it needs once.

## Before you start

On each machine, as root, a folder for what you change, so you can go back:

```
SET=<the set>; B=/root/ccs/pre-$SET; install -d -m 700 "$B"
```

The web server is reached as `ubuntu@<web server>` with `sudo` (root can't log in there).

## 1. Check it is attested (each machine itself)

The web server checks too, with its own ccs-sigs copy and its own `trusted-signers`. A
taken-over backend could bring both a release and the sums it is compared with.

`trusted-signers` holds the fingerprints of the people you trust to attest this set, and only
theirs:
- `/etc/ccs/trusted-signers` on the backend;
- `/etc/ccs-gate/trusted-signers` on the web server.

Take out a signer of the previous set who didn't attest this one: a throwaway key whose secret
wasn't really destroyed could attest anything later.

```
cp -a /etc/ccs/trusted-signers "$B/"           # the web server: /etc/ccs-gate/trusted-signers
git -C /opt/ccs-sigs pull -q --ff-only
cd /opt/ccs-bash && env CCS_SIGS_REPO=/opt/ccs-sigs TRUSTED_KEYS=/etc/ccs/trusted-signers \
    contrib/release/verify "$SET"              # the web server: verify ccs-gate-vX too
```

It prints each ID or sha256, how many signers agree (two by default) and the commits they name.
Too few: wait, or attest it yourself ([contrib/release](../contrib/release/README.md)).
`--min-signers 1` is for the testnet only: with one signer, the person who wrote a release is
also the only one vouching for it.

**A testnet may skip this step** and deploy its own releases unsigned: each machine still builds
the release from its commit and switches only to the ID the release notes publish (step 2), so a
release is what its tag holds; nothing says anyone else agrees. Set `CCS_UNATTESTED=1` in the
backend's `.env`, so `ccs config:check` warns of the unattested images instead of failing. Never
on mainnet: there, two people attest every set.

## 2. Build the images from those commits and compare

The loop keeps running meanwhile. Build from the attested commit, not the tag: a tag can move,
and the build runs as root. Use a clone of its own, so the running checkout stays as it is:

```
W=/root/ccs/src-ccs-bash; rm -rf "$W"; git clone -q https://github.com/plowsof/ccs-bash "$W"
git -C "$W" checkout -q <ccs-bash's commit>; git -C "$W" describe --tags     # the release
(cd "$W" && container/build.sh ccs-bash:<release>)                         # the backend
(cd "$W" && container/build.sh ccs-gate:<release> gate.Dockerfile)          # the web server's
docker image inspect ccs-bash:<release> --format '{{.Id}}'                  # must be IDB
```

Do the same for ccs-front-bash: `/root/ccs/src-ccs-front-bash`, its commit, `container/build.sh
ccs-front-bash:<release>`, which must give `IDF`. Any other ID: stop.
- **The gate's image** is built on the web server.
- **The backend's images** are each kept by a stopped container, so no cleanup removes them:
  `docker create --name ccs-bash-keep-<release> --network none "$IDB"`, and the same for
  ccs-front-bash.

A build that stops with `sources has files that are not in sources.lock`: a source an older
release needed is still in `container/sources/` (a download cache, not in git); move it aside.

## 3. The web server

**3a. A new design:** fetch it, check its sha256, unpack it beside the old ones, and add its
files to `design.sha256`. Nothing restarts.

```
cp -a /etc/ccs-gate/design.sha256 "$B/"
curl -fsSLo /tmp/d.zip https://github.com/plowsof/ccs-front-hugo/releases/download/<release>/ccs-front-hugo-<release>.zip
echo "$ZIP  /tmp/d.zip" | sha256sum -c -
unzip -q /tmp/d.zip -d /etc/ccs-gate/design/<release>
(cd /etc/ccs-gate/design/<release> && find . -type f ! -name '*.html' -exec sha256sum {} +) > /tmp/lines
flock /var/lib/ccs-gate/lock sh -c 'cat /tmp/lines >> /etc/ccs-gate/design.sha256'
```

The old designs stay: the gate takes a page of any of them, so the backend can switch later.
A changed `markdown.awk` goes beside the old one as `/etc/ccs-gate/markdown-<release>.awk`.

**3b. A new gate:**

```
D=/opt/ccs-bash/contrib/docker/web; cp -a "$D/.env" "$B/"
git -C /opt/ccs-bash fetch -q --tags && git -C /opt/ccs-bash checkout -q <ccs-bash's commit>
sed -i "s|^CCS_GATE_IMAGE=.*|CCS_GATE_IMAGE=$IDG|" "$D/.env"
cd "$D" && docker compose config -q && docker compose --profile init run --rm -T init && docker compose up -d
docker compose ps                    # gate, heartbeat, backup, www, tor: the new ID
```

The site is down for a few seconds while `www` and `tor` restart. The backup machine's compose
gets the same, with `--profile backup up -d backup`.

## 4. The backend, prepared

The loop keeps running. **4a. A new design:** unpacked beside the one in use.

```
curl -fsSLo /tmp/d.zip …; echo "$ZIP  /tmp/d.zip" | sha256sum -c -
rm -rf /opt/ccs-front-hugo/public.new && unzip -q /tmp/d.zip -d /opt/ccs-front-hugo/public.new
chmod -R u=rwX,go=rX /opt/ccs-front-hugo/public.new
```

## 5. The backend, switched between runs

Wait until a run has pushed: `ccs status` shows no run going, or `/var/lib/ccs/run/push/done`
changes. Then at once:

```
D=/opt/ccs-bash/contrib/docker/backend; cp -a "$D/.env" /opt/ccs-front-hugo/VERSION "$B/"
git -C /opt/ccs-bash rev-parse HEAD > "$B/commit"
git -C /opt/ccs-bash fetch -q --tags && git -C /opt/ccs-bash checkout -q <ccs-bash's commit>
sed -i -e "s|^CCS_BASH_IMAGE=.*|CCS_BASH_IMAGE=$IDB|" -e "s|^CCS_FRONT_IMAGE=.*|CCS_FRONT_IMAGE=$IDF|" "$D/.env"
cd "$D" && docker compose config -q && docker compose up -d
```

**5a. A new design**, in the same pause:

```
mv /opt/ccs-front-hugo/public /opt/ccs-front-hugo/public.<old release>
mv /opt/ccs-front-hugo/public.new /opt/ccs-front-hugo/public
echo "<release> $ZIP" > /opt/ccs-front-hugo/VERSION
```

`front` mounts `/opt/ccs-front-hugo`, so it sees the renamed `public`; nothing else restarts.
A design and a ccs-front-bash that need each other (a new `{{slot}}`) switch together; the
gate of step 3 must already know the slot.

## Check it worked

**The web server**, a few minutes after its step 3:

```
cd /opt/ccs-bash/contrib/docker/web && docker compose ps     # healthy (the gate's check runs every 5 minutes)
tail -n 5 /var/log/ccs-web/ccs-gate.log
ls /var/lib/ccs-gate/quarantine                                   # none: nothing was taken off the site
curl -sSo /dev/null -w '%{http_code}\n' https://<the site>/        # 200
```

The log's first push after a new gate, design or `markdown.awk` checks every page:
`checking 328 of 328 pages and JSON files (all of them: …)`. The push after it checks `0 of
328`, which only happens once the full check has passed and recorded what it checked against.
`held back …` lines name what didn't pass (IRC hears too).

**The backend:**
- the next run: every stage `ok` and the push `pushed` (`ccs status`);
- ccs-watch's check after it raises no alert;
- `ccs config:check` with nothing failing (it says when an image isn't in an attestation).

**Then:**
- replace the row in [the releases](handover.md#the-releases) with the new set, as a small
  ccs-bash PR;
- on each machine, take the previous set's signers out of `trusted-signers`, unless they
  attested this one too.

## Going back

- **The backend:** between runs, the `.env` and checkout from `$B`
  (`git -C /opt/ccs-bash checkout -q $(cat $B/commit)`), and the old `public` back in place
  (`public.<old release>`). Then `docker compose up -d`.
- **The web server:** the `.env` from `$B`, then init and `up -d`. Its `design.sha256` can keep
  the new lines.

The old images are still there, kept by their keep containers.

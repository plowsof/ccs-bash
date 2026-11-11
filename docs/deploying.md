# Deploying a release

**When:** a release of ccs-bash (ccs-front-bash comes in it, vendored) or ccs-front-hugo has been attested in
[ccs-sigs](https://github.com/plowsof/ccs-sigs) ([releasing](releasing.md)) and should run on the
machines. Nothing changes on a machine until you do this.

The set is the releases together, as ccs-sigs names it, e.g.
`ccs-bash-v0.2.53+ccs-front-hugo-v0.1.29`. Below, `SET` is that name, and `IDB`, `IDG` and `ZIP`
are what `verify` prints for it:
- `IDB`: ccs-bash's image ID (the backend's);
- `IDG`: the gate's (the web server's, with the vendored ccs-front-bash in it);
- `ZIP`: the design zip's sha256.

**The backend stays running.** The web server goes first: it builds the site from the backend's
`site-data.json`, which old and new releases write alike ([upgrading](upgrading.md) says when one
doesn't). The backend is switched between two runs. Don't stop it: the web server's heartbeat
alerts after 15 minutes without a push.

## What to do for what changed

| Changed | Web server | Backend |
|---|---|---|
| the design only (ccs-front-hugo) | steps 1, 3a | its sums, first (3a) |
| ccs-bash (any code: the gate, the backend, the vendored ccs-front-bash) | steps 1, 2, 3b | steps 1, 2, 4 |
| a design and a ccs-front-bash that need each other (a new `{{slot}}`) | 3b, then 3a at once | — |

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
and the build runs as root. Use a clone of its own, so the running checkout stays as it is.
Paste the block whole: `set -e` stops it at the first step that fails, so if the commit can't be
checked out (a mistyped commit, or history rewritten on GitHub), no other code is built as root.
`C` is the commit `verify` printed, all 40 characters:

```
( set -euo pipefail
C=<ccs-bash's commit> W=/root/ccs/src-ccs-bash
rm -rf "$W"; git clone -q https://github.com/plowsof/ccs-bash "$W"
git -C "$W" checkout -q --detach "$C"
[[ $(git -C "$W" rev-parse HEAD) == "$C" ]]
git -C "$W" describe --tags                                       # the release
cd "$W"
container/build.sh ccs-bash:<release>                             # on the backend
# container/build.sh ccs-gate:<release> gate.Dockerfile           # instead, on the web server
docker image inspect ccs-bash:<release> --format '{{.Id}}' )      # must be IDB
```

Any other ID, or the block stopping early: stop.
- **The gate's image** is built on the web server.
- **The backend's image** is kept by a stopped container, so no cleanup removes it:
  `docker create --name ccs-bash-keep-<release> --network none "$IDB"`.

A build that stops with `sources has files that are not in sources.lock`: a source an older
release needed is still in `container/sources/` (a download cache, not in git); move it aside.

## 3. The web server

**3a. A new design:** fetch it, check its sha256, and unpack it beside the old ones. The gate
builds with the newest release in `design/` from its next push on: install it with the gate
whose ccs-front-bash fills it (the handover's releases table). Nothing restarts.

Paste it whole: a zip that isn't the attested one stops it before anything is unpacked.

```
( set -euo pipefail
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
curl -fsSLo "$d/d.zip" https://github.com/plowsof/ccs-front-hugo/releases/download/<release>/ccs-front-hugo-<release>.zip
echo "$ZIP  $d/d.zip" | sha256sum -c -
unzip -q "$d/d.zip" -d /etc/ccs-gate/design/<release>.new
mv /etc/ccs-gate/design/<release>.new /etc/ccs-gate/design/<release> )
```

The old designs can stay (going back: move the new one out).

**First, on the backend:** the same zip's sums beside the old ones, which ccs-watch checks the
pages' images against (its design files, byte for byte), so that the old pages and the new both
pass while the gate moves over. Then the web server's steps above.

```
( set -euo pipefail
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
curl -fsSLo "$d/d.zip" https://github.com/plowsof/ccs-front-hugo/releases/download/<release>/ccs-front-hugo-<release>.zip
echo "$ZIP  $d/d.zip" | sha256sum -c -
unzip -q "$d/d.zip" -d "$d/x"
cp -a /etc/ccs-front/design.sha256 "$B/" 2> /dev/null || true
(cd "$d/x" && find . -type f | sort | xargs -d '\n' sha256sum) >> /etc/ccs-front/design.sha256 )
```

Once the old design is gone from the web server, its lines can go: the file made again from the
new zip alone.

**3b. A new gate:**

```
( set -euo pipefail
D=/opt/ccs-bash/contrib/docker/web; cp -a "$D/.env" "$B/"
git -C /opt/ccs-bash fetch -q --tags; git -C /opt/ccs-bash checkout -q --detach <ccs-bash's commit>
sed -i "s|^CCS_GATE_IMAGE=.*|CCS_GATE_IMAGE=$IDG|" "$D/.env"
cd "$D"; docker compose config -q; docker compose --profile init run --rm -T init; docker compose up -d
docker compose ps )                  # gate, heartbeat, backup, www, tor: the new ID
```|^CCS_GATE_IMAGE=.*|CCS_GATE_IMAGE=$IDG|" "$D/.env"
cd "$D" && docker compose config -q && docker compose --profile init run --rm -T init && docker compose up -d
docker compose ps                    # gate, heartbeat, backup, www, tor: the new ID
```

The site is down for a few seconds while `www` and `tor` restart. The backup machine's compose
gets the same, with `--profile backup up -d backup`.

## 4. The backend, switched between runs

Wait until a run has pushed: `ccs status` shows no run going, or `/var/lib/ccs/run/push/done`
changes. Then at once:

```
( set -euo pipefail
D=/opt/ccs-bash/contrib/docker/backend; cp -a "$D/.env" "$B/"
git -C /opt/ccs-bash rev-parse HEAD > "$B/commit"
git -C /opt/ccs-bash fetch -q --tags; git -C /opt/ccs-bash checkout -q --detach <ccs-bash's commit>
sed -i "s|^CCS_BASH_IMAGE=.*|CCS_BASH_IMAGE=$IDB|" "$D/.env"
cd "$D"; docker compose config -q; docker compose up -d )
```|^CCS_BASH_IMAGE=.*|CCS_BASH_IMAGE=$IDB|" "$D/.env"
cd "$D" && docker compose config -q && docker compose up -d
```

## Check it worked

**The web server**, a few minutes after its step 3:

```
cd /opt/ccs-bash/contrib/docker/web && docker compose ps     # healthy (the gate's check runs every 5 minutes)
tail -n 5 /var/log/ccs-web/ccs-gate.log
curl -sSo /dev/null -w '%{http_code}\n' https://<the site>/        # 200
```

The log's first push after a new gate or design builds the site: `built the site from
site-data.json (the design v0.1.29, the proposals at 1a2b3c4): live`. `took … off the site` lines
name a page that didn't pass, `held back` or `could not build` a build that didn't go live (IRC
hears too).

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
  (`git -C /opt/ccs-bash checkout -q $(cat $B/commit)`). Then `docker compose up -d`.
- **The web server:** the `.env` from `$B`, then init and `up -d`; a new design moved out of
  `/etc/ccs-gate/design/`.

The old images are still there, kept by their keep containers.

# Patching: Go, Caddy, Tor and the StageX images

**When:** GitHub emails that a weekly workflow of ccs-bash failed (Mondays):
- **`upstream`:** StageX has a newer release of an image pinned in `container/images`, or Tor has
  a newer release than `container/sources.lock` pins.
- **`vulncheck`:** a known Go vulnerability in code `ccs-check` calls (Go's standard library, as
  StageX's pinned Go has it), or one in the pinned Caddy that isn't in
  `container/caddy-vulns-accepted`.

Nothing changes by itself: a pin moves only by a reviewed pull request, then a release.

## Read the failure first

Open the failed run (`gh run list --workflow vulncheck.yml --limit 1`, then `gh run view <id>
--log-failed`). It names what is newer, or each vulnerability's ID (`GO-2026-NNNN`) and summary.

| What failed | Do |
|---|---|
| `upstream`: a newer StageX image | [refresh the pins](#refresh-the-stagex-pins) when convenient, or at once if `vulncheck` also fails |
| `upstream`: a newer Tor | [a new Tor](#a-new-tor) |
| `vulncheck`: in `ccs-check` | [refresh the pins](#refresh-the-stagex-pins): the fix is StageX's next Go |
| `vulncheck`: in Caddy | [decide about it](#a-vulnerability-in-caddy) |

## Refresh the StageX pins

```
git checkout -b pins origin/master
container/update-images.sh      # every pin to StageX's latest; checks two or more StageX maintainers signed each
git diff container/images       # which images moved
```

`update-images.sh` also stores the new signatures (`container/sigs/`, via `update-sigs.sh`).
StageX publishes a new Go some days after Go does. If the fix isn't in StageX's latest yet, the
diff doesn't move `go`: wait for it, and see the next section if it's Caddy.

Then:
1. **Update the versions** the docs list in [web-server.md](web-server.md) ("The gate's image",
   the package table and its StageX release line) from what moved.
2. **Open a PR.** CI rebuilds both images and runs every test on them: `gate.sh`, `www.sh`,
   `image.sh`, the regtest.
3. **Merge when green**, then [release](releasing.md) a new ccs-bash version and
   [deploy](deploying.md) it. Only ccs-bash changed, so the other two keep their versions in the
   new set.

**A new maintainer key at StageX:** `container/update-keys.sh` refreshes
`container/stagex-keys.asc`. A new fingerprint in its diff is a new person trusted to sign:
check them with StageX ([MAINTAINERS](https://codeberg.org/stagex/stagex/src/branch/main/MAINTAINERS))
before merging.

## A vulnerability in Caddy

`www` serves a fixed, small configuration (`contrib/docker/web/Caddyfile`):
- HTTP/1.1 only;
- `Range` dropped;
- request headers capped at 16 KB;
- no admin API, proxy, templates or gRPC.

Many of Go's and Caddy's vulnerabilities are in code it never reaches. For each new ID, read its
summary and decide:
- **It can't be reached** (HTTP/2, a proxy, a feature the Caddyfile doesn't use): add a line
  `GO-YYYY-NNNN  why` under the matching comment in `container/caddy-vulns-accepted`, as a PR.
  `vulncheck` then passes. When a later Caddy no longer has it, the workflow lists it as gone:
  take the line out.
- **It can be reached:** refresh the pins (above) once StageX's Caddy has the fix. Until then,
  see whether a Caddyfile change avoids it (as `Range` and the header cap do), as a PR and a
  release.

## A new Tor

`gate.Dockerfile` builds Tor from its source tarball, pinned by sha256 in `container/sources.lock`.
For a new version `0.4.X.Y`:

1. Download the tarball, its `.sha256sum` and the `.sha256sum.asc` from
   `https://dist.torproject.org/`.
2. Check the `.asc`. It must be signed by Tor's release signers, whose fingerprints are in
   `sources.lock`'s comment (`gpg --verify tor-0.4.X.Y.tar.gz.sha256sum.asc`, after importing
   their keys). Then `sha256sum -c tor-0.4.X.Y.tar.gz.sha256sum`.
3. In `container/sources.lock`, the Tor line's sha256, size and both URLs. In
   `container/gate.Dockerfile`, the two `tor-0.4.9.15` paths. In `docs/web-server.md`, the
   version in the table.
4. A PR (CI builds Tor and runs `www.sh`, which serves the onion), then a release and a deploy,
   as above.

## After deploying

[Check it worked](deploying.md#check-it-worked). The next Monday's runs should pass. A
vulnerability `vulncheck` only lists, without failing, waits for the next release made anyway
([ccs-check](ccs-check.md#keeping-it-patched)).

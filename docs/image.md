# The pinned image

Option B's image holds only pinned, source-built parts (about 71 MB: git, rsync and ssh for the
compose's pull, push and backup make most of it):

- **[StageX](https://stagex.tools) packages**, pinned by digest in `container/images`: bash, curl,
  jq, ca-certificates, git, rsync, openssh (ssh only) and their libraries. StageX builds everything from source from a tiny
  bootstrap; two or more maintainers reproduce and sign each release, which every build checks.
- **busybox, built here** from upstream source pinned by sha256 in `container/sources.lock`
  (StageX's sum), with only the applets in `container/busybox-applets` (no shell, `nc`, `wget`...).
- **Built by StageX's BuildKit** (and runc), pinned and checked like the rest, not by the
  host Docker's.

`container/build.sh` (needs Docker with buildx and its own image store, not the containerd one,
whose image IDs are the manifest's digest: [setup](setup.md#dependencies); `git`, `gpg`, `jq`):

1. **Checks the signatures** of every pin ([below](#signatures)).
2. **Downloads** the pinned images and the sources; `fetch.sh` keeps only files whose sha256 matches.
3. **Makes the builder:** `builder.Dockerfile` copies StageX's BuildKit into an image, run as a
   buildx builder `stagex-buildkit-<id>` (privileged, like any buildx builder), the same one
   ccs-front-bash's and ccs-front-hugo's builds use while their pins are the same.
4. **Builds** with `--network none`: BuildKit fetches the pins by digest, the steps get no
   network. It rechecks the sources, compiles busybox with StageX's toolchain, and
   sets every file time to the commit's.

So the same commit always builds to the same image ID, anywhere; `build.sh` prints it.
`container/check-pinned.sh` proves it on every push: two clean builds from separate clones and
one on a cache from another commit must agree.

## Signatures

StageX publishes an image once two or more maintainers have rebuilt it and signed its digest
([containers signature format](https://github.com/containers/image/blob/main/docs/containers-signature.5.md),
at `https://sigs.stagex.tools`). A copy of them for every pin is kept in `container/sigs/`
(`container/update-sigs.sh` makes it when the pins change), so a build reads them here and needs
nothing from that site; stored or fetched, they are checked the same way. `container/verify-images.sh`
checks, for each pin:

- the registry's index hashes to the pin; its `linux/<arch>` manifest is what's signed;
- a signature counts if it is good, by a key in `container/stagex-keys.asc`, and names that
  repo and manifest;
- **two different maintainers** signed, so one stolen key isn't enough.

A maintainer's key that expires doesn't stop the builds: a signature we verified while its key was
valid still counts. `container/sigs-verified` lists them (each signature file's sha256 and
signer), written by `verify-images.sh --record`, which `update-sigs.sh` runs; committed with
`sigs/`, so git dates each. Not a signature that first arrives after its key expired (a signature's
date is the signer's to write), and never one by a revoked key.

`stagex-keys.asc` holds the keys of the people in StageX's
[MAINTAINERS](https://codeberg.org/stagex/stagex/src/branch/main/MAINTAINERS), fingerprints
listed at the top. `container/update-keys.sh` refreshes it; a new fingerprint in the diff is a
new person trusted to sign, so check it with StageX first.

This proves StageX's maintainers reproduced and signed what we pin, not that we rebuilt StageX
([Reproduce StageX](https://docs.stagex.tools/get-started/reproduce-stagex/)).

## Changing the pin

`container/update-images.sh` pins every image to StageX's current release, stores its
signatures in `container/sigs/` and checks them; review the diff, commit, rebuild. A new builder pin makes a new builder; remove old
ones with `docker buildx rm stagex-buildkit-<id>`. For a newer busybox, change its
line in `container/sources.lock` and the version in the Dockerfile. More applets go in
`container/busybox-applets`.

## Releases

Push a tag `vX.Y.Z` on `master` (or make the release on GitHub, which makes the tag). The
`release` workflow builds, tests, runs `check-pinned.sh`, pushes `ghcr.io/plowsof/ccs-bash:vX.Y.Z`
and adds the pull-by-digest line and image ID to the release notes. If it fails the release has
no notes: rerun it, or delete tag and release and redo them. A release proves nothing by
itself; anyone can rebuild the tag and compare IDs ([setup](setup.md) step 3), and sign what they
got into [ccs-sigs](https://github.com/plowsof/ccs-sigs) with `contrib/release/build` and
`attest`, as Feather Wallet's releases are attested ([contrib/release](../contrib/release/README.md)).

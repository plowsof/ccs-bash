# The pinned image

Option B runs ccs-bash in a container image built only from pinned, source-built parts:

- **[StageX](https://stagex.tools) packages**, pinned by digest in `container/images`: bash,
  curl, jq, ca-certificates, and the libraries they need (musl, ncurses, openssl, zstd, zlib,
  libpng). StageX builds every package from source, starting from a tiny bootstrap, and several
  people rebuild and sign each release. Every build checks those signatures (below).
- **busybox and qrencode, built here** from their upstream source, pinned by sha256 in
  `container/sources.lock` (the same sums StageX pins). busybox gets only the 28 applets in
  `container/busybox-applets`, so there is no shell, `nc`, `wget`, ... in the image;
  qrencode is built with PNG output, which StageX's own leaves out.

- **The builder is StageX's too.** The build runs in StageX's BuildKit (with its runc), pinned
  and signed like the packages, not in the BuildKit that comes with the host's Docker.

The image is about 28 MB and is built by `container/build.sh` (the host needs Docker with
buildx, `git`, `gpg` and `jq`):

1. **Check the signatures** (network): `verify-images.sh`, see [Signatures](#signatures).
2. **Download** (network): the StageX images, by digest, and the source tarballs in
   `container/sources.lock`. `fetch.sh` uses plain curl and keeps a file only if its sha256
   matches.
3. **The builder:** `builder.Dockerfile` copies StageX's BuildKit, runc and what they need into
   an image (only copies, nothing runs), which becomes a buildx builder of its own,
   `ccs-bash-builder-<id>`, running as a privileged container like any buildx builder.
4. **Build:** `docker buildx build --network none` with that builder. BuildKit fetches the
   pinned images by digest; the build steps themselves have no network. The Dockerfile
   checks the sources against the lock again, compiles busybox and qrencode with StageX's
   compiler image, and puts the image together from the pinned packages, with every file
   time set to the commit's.

The result is a **pinned image**: its hash is pinned along with everything that goes into it.
The code (the git commit), the StageX packages (their digests) and the sources (their sha256)
are fixed, so the same commit always builds to the same image hash, wherever and whenever it is
built; `build.sh` prints it. An image built elsewhere can be checked by building the same commit
and comparing hashes, and `container/check-pinned.sh` does exactly that (two clean builds from
separate clones, and one with a build cache left by another commit), in CI on every push too.

## Signatures

StageX releases an image only once two or more maintainers have each rebuilt it from source,
got the same digest, and signed that digest with their OpenPGP keys (the
[containers signature format](https://github.com/containers/image/blob/main/docs/containers-signature.5.md),
served at `https://sigs.stagex.tools`). `container/verify-images.sh` checks this for every
line of `container/images`, before every build (and in CI):

- the registry's index for the pinned digest must hash to it; the signatures are on the
  index's `linux/<arch>` manifest, so that is the digest checked;
- a signature counts only if it is good, made by a key in `container/stagex-keys.asc`, and
  names that repo and that manifest digest;
- at least **two different maintainers** must have signed, as StageX requires. One isn't
  enough, so a single stolen key can't get an image past it.

`container/stagex-keys.asc` holds the public keys of the people in StageX's
[MAINTAINERS](https://codeberg.org/stagex/stagex/src/branch/main/MAINTAINERS) file, with their
fingerprints listed at the top. `container/update-keys.sh` refreshes it (fingerprints from
MAINTAINERS, keys from keys.openpgp.org); a new fingerprint in its diff is a new person trusted
to sign, so check it against StageX's own announcements. Signatures by keys not in it (former
maintainers, say) are not counted.

What this proves: the digests we pin are the ones StageX's maintainers reproduced and signed.
It doesn't rebuild StageX here; that is [Reproduce StageX](https://docs.stagex.tools/get-started/reproduce-stagex/).

## Changing the pin

For newer StageX packages, run `container/update-images.sh` (it pins every image in
`container/images` to StageX's current release and checks their signatures), review the diff,
commit it, and rebuild with `container/build.sh`. A new builder pin gives a new builder; old
ones can go with `docker buildx rm ccs-bash-builder-<id>`. For a newer busybox or qrencode, change its line in
`container/sources.lock` (url and sha256, e.g. the ones StageX pins) and the version in the
Dockerfile. To give busybox another applet, add it to `container/busybox-applets`.

## Releases

Push a tag `vX.Y.Z` on `master`, or make the release on GitHub's release page (which makes
the tag). Either way the `release` workflow builds the image, runs the tests in it, runs
`check-pinned.sh`, pushes it to `ghcr.io/plowsof/ccs-bash:vX.Y.Z`, and puts the pull-by-digest
line and the image ID in the release notes (below any text written on the release page). If
it fails, the release has no notes: fix and rerun it, or delete the tag and release and make
them again. Publishing makes nothing trusted by itself: anyone can rebuild the tag and compare
IDs ([setup](setup.md) step 3B).

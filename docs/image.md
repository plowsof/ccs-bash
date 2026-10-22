# The pinned image

Option B runs ccs-bash in a container image built only from pinned, source-built parts:

- **[StageX](https://stagex.tools) packages**, pinned by digest in `container/images`: bash,
  curl, jq, ca-certificates, and the libraries they need (musl, ncurses, openssl, zstd, zlib,
  libpng). StageX builds every package from source, starting from a tiny bootstrap, and several
  people rebuild and sign each release.
- **busybox and qrencode, built here** from their upstream source, pinned by sha256 in
  `container/sources.lock` (the same sums StageX pins). busybox gets only the 28 applets in
  `container/busybox-applets`, so there is no shell, `nc`, `wget`, ... in the image;
  qrencode is built with PNG output, which StageX's own leaves out.

The image is about 28 MB and is built in two steps by `container/build.sh`:

1. **Download** (network): the StageX images, by digest, and the source tarballs in
   `container/sources.lock`. `fetch.sh` uses plain curl and keeps a file only if its sha256
   matches.
2. **Build** (no network): `docker buildx build --network none` (buildx drives Docker's BuildKit
   engine, which is what sets every file time in the image to the commit's). The Dockerfile
   checks the sources against the lock again, compiles busybox and qrencode with StageX's
   compiler image, and puts the image together from the pinned packages. Nothing can be fetched.

The result is a **pinned image**: its hash is pinned along with everything that goes into it.
The code (the git commit), the StageX packages (their digests) and the sources (their sha256)
are fixed, so the same commit always builds to the same image hash, wherever and whenever it is
built; `build.sh` prints it. An image built elsewhere can be checked by building the same commit
and comparing hashes, and `container/check-pinned.sh` does exactly that (two clean builds from
separate clones, and one with a build cache left by another commit), in CI on every push too.

## Changing the pin

For newer StageX packages, run `container/update-images.sh` (it pins every image in
`container/images` to StageX's current release), review the diff, commit it, and rebuild with
`container/build.sh`. For a newer busybox or qrencode, change its line in
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

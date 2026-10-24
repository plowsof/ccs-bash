# Attesting a release

Anyone can rebuild a CCS release and say, with their own GPG key, what came out: the same
image ID or sha256 from the same tag, on their machine as on everyone else's. The signatures are
collected in [ccs-sigs](https://github.com/plowsof/ccs-sigs), one folder per release and signer.
(The signed subaddress list isn't attested here: a Core Team member makes and signs it, and
contributors can regenerate it and confirm its hash; see ccs-front-bash's docs/setup.md, step 5.)
A release is trustworthy when several people who don't share a machine have attested the same.

This is [Feather Wallet](https://featherwallet.org)'s way of doing it, taken over as closely as
we could: tobtoht's `contrib/guix/guix-attest` and `guix-verify`, the
[feather-sigs](https://github.com/feather-wallet/feather-sigs) layout and its pull-request
check. Thank you, tobtoht. Where Feather builds with Guix, each CCS repository builds itself
with its own pinned StageX `container/build.sh`, so `build` only clones the tag and records the
result.

| Script | From | Does |
|---|---|---|
| `build` | Feather's `guix-build`, in spirit | builds one release (a tag of ccs-bash, ccs-front-bash or ccs-front-hugo) into `output/<name>/SHA256SUMS.part` |
| `attest` | Feather's `guix-attest` | writes `<name>/<signer>/all.SHA256SUMS` into your ccs-sigs checkout and signs it (`.asc`) |
| `verify` | Feather's `guix-verify` | checks every signature against `builder-keys/` and that all signers agree |

## What it takes

Git, Docker with buildx, gpg, curl and jq. Measured
on a machine with nothing cached (a fresh attester), building the three in this order:

| Build | Time | Docker disk |
|---|---|---|
| ccs-bash | about 3 minutes | 2.3 GB (the pinned StageX images and the builder) |
| ccs-front-bash | about a minute | 0.2 GB (it shares ccs-bash's builder and downloads) |
| ccs-front-hugo | under half a minute | 0.2 GB |
| **all three** | **about 5 minutes** | **2.7 GB** |

Whichever of ccs-bash and ccs-front-bash comes first does the big download; the outputs
themselves are a few KB. The three share one builder while their pinned StageX images are the
same (from ccs-bash v0.2.7, ccs-front-bash v0.1.8 and ccs-front-hugo v0.1.7; older releases each
make their own, about 2 GB more). Later builds reuse it all. Every step is shown as it happens,
and `build` says whether its result is the one the release notes publish.

To get the space back once you have attested, `contrib/release/clean`: it removes only what
`build` made (its builders and their caches, their images, and `output/`), and shows Docker's
disk before and after.

## Attesting

```
git clone --recursive https://github.com/plowsof/ccs-bash && cd ccs-bash   # ccs-sigs comes along, at external/ccs-sigs
git submodule update --remote external/ccs-sigs                            # the newest attestations

contrib/release/build                                                      # the newest release of all three

env SIGNER=<fingerprint>=<github username> contrib/release/attest
```

By default `build` takes each repository's newest release tag (the set at the top of the handover's
[releases table](../../docs/handover.md#the-releases)) and says which before it starts. Or name
the releases yourself, any of the three:

```
contrib/release/build ccs-bash v0.2.8 ccs-front-bash v0.1.11 ccs-front-hugo v0.1.9
contrib/release/build ccs-front-hugo v0.1.9                                # just one
contrib/release/build ccs-bash                                             # the newest of one
```

Your first time, add your public key in the same pull request (the check refuses a key without
an attestation):

```
gpg --export --armor <fingerprint> > external/ccs-sigs/builder-keys/<github username>.asc
```

Then send it to ccs-sigs as a pull request. First fork https://github.com/plowsof/ccs-sigs on
GitHub (its Fork button, or `gh repo fork plowsof/ccs-sigs --clone=false`). The commit and the pull
request are titled as feather-sigs' are, `Add <github username> <set>`, the set being the folder
`attest` named (`Attesting to build outputs for: '...'`):

```
cd external/ccs-sigs
git checkout -b <github username>-attest
git add -A && git commit -m "Add <github username> ccs-bash-v0.2.8+ccs-front-bash-v0.1.11+ccs-front-hugo-v0.1.9"
git remote add fork https://github.com/<github username>/ccs-sigs && git push fork HEAD
```

GitHub prints a link to open the pull request: open it against `master` with the commit's title.
Or, with `gh`:

```
gh pr create -R plowsof/ccs-sigs --base master --head <github username>:<github username>-attest --fill
```

ccs-sigs' owner pushes the branch to ccs-sigs itself (`git push origin HEAD`) instead of a fork.
To try the process out with a throwaway key, use the `testnet` branch instead of `master`:
`git checkout -b <name> origin/testnet` before `attest`, and `--base testnet`.

Then, back in `ccs-bash`, give the disk back: `contrib/release/clean` (about 2.7 GB).

Its `lint` check
(feather-sigs', from Bitcoin Core's guix.sigs) lets a pull request only add attestation files,
in pairs, and builder keys, and checks each signature against its signer's key.

## What is attested

Everything you built in one run goes into **one** file, signed once (as Feather's one
`all.SHA256SUMS` per version), in a folder named after the set:
`ccs-bash-v0.2.7+ccs-front-bash-v0.1.9+ccs-front-hugo-v0.1.8/<you>/all.SHA256SUMS`. One line per
release:

| Release | Its line |
|---|---|
| ccs-bash, ccs-front-bash | the image ID, named `<release>-<commit>.image-id` |
| ccs-front-hugo | the zip's sha256, named as the release's asset (`sha256sum -c` checks a download) |

## Checking a release before using it

As Feather does: after at least one other signer's attestation is in ccs-sigs, fetch the newest
and check them all (CCS_SIGS_REPO defaults to the submodule):

```
git submodule update --remote external/ccs-sigs
contrib/release/verify
```

Or one release: it counts every set it is in, so signers who built different sets still add up,
and its line must be the same for all of them:

```
env CCS_SIGS_REPO=external/ccs-sigs contrib/release/verify ccs-bash-v0.2.7
```

Then compare the attested ID or sha256 with the release notes and with what you are about to
run (`docker image inspect ccs-bash --format '{{.Id}}'`, `sha256sum` of the zip, the `.pin`).

## Licence

`attest` and `verify` are adapted from Feather Wallet's `contrib/guix/guix-attest` and
`guix-verify`, which are under this licence:

```
The MIT License (MIT)

Copyright (c) 2009-2022 The Bitcoin Core developers
Copyright (c) 2009-2022 Bitcoin Developers
Copyright (c) 2022-2022 The Monero Project

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
```

# Attesting a release

Anyone can rebuild a CCS release and say, with their own GPG key, what came out: the same
image ID or sha256 from the same tag, on their machine as on everyone else's. The signatures are
collected in [ccs-sigs](https://github.com/plowsof/ccs-sigs), one folder per release and signer.
A release is trustworthy when several people who don't share a machine have attested the same.

This is [Feather Wallet](https://featherwallet.org)'s way of doing it, taken over as closely as
we could: tobtoht's `contrib/guix/guix-attest` and `guix-verify`, the
[feather-sigs](https://github.com/feather-wallet/feather-sigs) layout and its pull-request
check. Thank you, tobtoht. Where Feather builds with Guix, each CCS repository builds itself
with its own pinned StageX `container/build.sh`, so `build` only clones the tag and records the
result.

| Script | From | Does |
|---|---|---|
| `build` | Feather's `guix-build`, in spirit | builds one release (a tag of ccs-bash, ccs-front-bash or ccs-front-hugo, or a subaddress list) into `output/<name>/SHA256SUMS.part` |
| `attest` | Feather's `guix-attest` | writes `<name>/<signer>/all.SHA256SUMS` into your ccs-sigs checkout and signs it (`.asc`) |
| `verify` | Feather's `guix-verify` | checks every signature against `builder-keys/` and that all signers agree |

## What it takes

Git, Docker with buildx, gpg, curl and jq; for a subaddress list also monero-wallet-rpc. Measured
on a machine with nothing cached (a fresh attester):

| Build | Time | Docker disk |
|---|---|---|
| ccs-bash | about 4 minutes | 2.3 GB |
| ccs-front-bash | about 4 minutes | 2.1 GB |
| ccs-front-hugo | under half a minute | 0.2 GB |
| a subaddress list (15,000) | about a minute | none (a few MB in a temporary folder) |

About 8 minutes and 4.6 GB for the three; the outputs themselves are a few KB. Later builds reuse
the pinned StageX images and the builders. Every step is shown as it happens, and `build` says
whether its result is the one the release notes publish.

To get the space back afterwards:

```
docker buildx ls | grep -oE '^ccs-[a-z-]+-builder-[0-9a-f]+' | sort -u | xargs -r -n 1 docker buildx rm
docker images --format '{{.Repository}}:{{.Tag}}' | grep -E '^stagex/|^ccs-[a-z-]+-builder' | xargs -r docker rmi
```

## Attesting

```
git clone https://github.com/plowsof/ccs-bash && cd ccs-bash
git clone https://github.com/<you>/ccs-sigs external/ccs-sigs       # your fork (ccs-sigs' owner: a branch)

contrib/release/build ccs-bash v0.2.6
contrib/release/build ccs-front-bash v0.1.7
contrib/release/build ccs-front-hugo v0.1.6
WALLET_RPC=/path/to/monero-wallet-rpc contrib/release/build subaddresses testnet 15000   # asks for the address and view key

env SIGNER=<fingerprint>=<github username> contrib/release/attest
```

Your first time, add your public key in the same pull request (the check refuses a key without
an attestation):

```
gpg --export --armor <fingerprint> > external/ccs-sigs/builder-keys/<github username>.asc
```

Then commit in `external/ccs-sigs`, push to your fork and open a pull request. Its `lint` check
(feather-sigs', from Bitcoin Core's guix.sigs) lets a pull request only add attestation files,
in pairs, and builder keys, and checks each signature against its signer's key.

## What is attested

| Folder in ccs-sigs | The line in `all.SHA256SUMS` |
|---|---|
| `ccs-bash-v0.2.6` | the image ID, named `ccs-bash-v0.2.6-<commit>.image-id` |
| `ccs-front-bash-v0.1.7` | the image ID, the same way |
| `ccs-front-hugo-v0.1.6` | the zip's sha256, named as the release's asset (`sha256sum -c` checks a download) |
| `subaddresses-testnet-15000` | the regenerated list's sha256: the one its `.pin` must name |

## Checking a release before using it

```
env CCS_SIGS_REPO=external/ccs-sigs contrib/release/verify ccs-bash-v0.2.6
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

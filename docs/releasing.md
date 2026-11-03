# Releasing

**When:** a change to ccs-bash, ccs-front-bash or ccs-front-hugo is merged and should run on the
machines. Each repository releases on its own; what runs is a set of the three
([the releases](handover.md#the-releases)).

There are four steps: tag, attest, deploy, then record the set.

## 1. Tag the release

On the repository's `master`, after its CI passed on the merge:

```
git fetch -q origin && git tag -a vX.Y.Z origin/master -m "vX.Y.Z: <what changed, one line>"
git push origin vX.Y.Z
```

The repository's `release` workflow takes it from there. It builds, tests, checks that it builds
the same twice, and publishes the result with its ID or sha256 in the release notes:

| Repository | Publishes |
|---|---|
| ccs-bash | `ghcr.io/plowsof/ccs-bash` and the gate's image beside it: their pull-by-digest lines and image IDs |
| ccs-front-bash | its image: pull line and image ID |
| ccs-front-hugo | the design zip and its sha256 |

Wait until it's green (`gh run list --workflow release.yml --limit 1`). If it failed, the
release has no notes: rerun it, or delete the tag and release and do them again.

**Versions:** the third number for fixes and small changes, the second for a change the other
repositories must follow (a new `{{slot}}`, a changed output).

## 2. Attest the set

A release proves nothing by itself. Anyone can rebuild the tag and compare: that is what ccs-sigs
collects, one folder per set and signer. On any machine with Docker, gpg and git (about 5
minutes and 2.7 GB the first time):

```
git clone --recursive https://github.com/plowsof/ccs-bash && cd ccs-bash
git submodule update --remote external/ccs-sigs
contrib/release/build                                  # the newest of all three; says if they match the release notes
env SIGNER=<fingerprint>=<github username> contrib/release/attest
```

`attest` commits to a branch in `external/ccs-sigs` and prints the push and pull request to
make. Open it, wait for its check (it verifies the signature and the layout), and merge.
[contrib/release](../contrib/release/README.md) has the details.

**Who attests:** the default the machines require is two signers who agree. Each builds on their
own machine with their own key. On the testnet, one throwaway key a set has been used, with
`--min-signers 1`: then the person who released is the only one vouching for it. On mainnet, ask
at least one other person, who isn't the releaser, to build and attest.

## 3. Deploy

[Deploying a release](deploying.md): the web server first, then the backend between runs.

## 4. Record the set

Replace the row in [the releases](handover.md#the-releases): the date, the three versions, and
the attestation (signers, ccs-sigs PR). Do it as a small ccs-bash PR, merged once its CI is
green.

## A release of only one repository

The set still changes: the other two keep their versions, and the new set is attested whole
(`build` builds all three, by default the newest of each). On the machines, only the changed
part is deployed ([what to do for what changed](deploying.md#what-to-do-for-what-changed)).

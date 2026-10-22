# When something is wrong

Where to look: `/var/log/ccs-bash.log` (every run), and with [setup](setup.md) step 7
`journalctl -u ccs-bash -u ccs-wallet-rpc`.

| In the log | Meaning |
|---|---|
| `curl: (22) ... error: 401` | The wallet login is wrong. Check it outside ccs-bash: `curl --digest -u 'ccs:<rpc password>' http://127.0.0.1:18082/json_rpc -d '{"jsonrpc":"2.0","id":0,"method":"get_version"}'`. The config is read by bash, so a key given twice (say an old empty `RPC_PASSWORD=` further down) quietly wins: give each key once. |
| `main address is not WALLET_ADDRESS` | Another wallet answers on that port. Nothing was written. |
| `donations at subaddress ..., which proposals.csv doesn't have` | The state file is missing entries, see [Moving from ccs-back](migrating.md), step 3. Nothing was written. |
| `could not fetch ideas from GitLab` | GitLab is down; the previous Ideas list is kept. The proposals `git pull` gives up after 40 seconds. |
| `skipping <file>: ...` | That proposal's frontmatter isn't read (the reason follows); it is left off the site. |

Building the image (B), `container/build.sh` stops with `error: <name>: 1 of 2 maintainer
signatures` when a pinned StageX image isn't signed by two maintainers whose keys are in
`container/stagex-keys.asc`. Don't work around it: if StageX added a maintainer, refresh the
keys ([Signatures](image.md#signatures)); otherwise ask StageX before building with that pin.

Inside the image (B) there is no shell but bash, and only the busybox commands in
`container/busybox-applets` (no `head`, `less`, `ps`, ...). To look around:
`docker run --rm -it --entrypoint bash ccs-bash`, with the same `-v` options as `ccs-bash-run`
to see what a run sees.

If your build of a commit gives another image ID than CI's: build again from a clean cache,
`NO_CACHE=1 container/build.sh`. Since #6 a warm cache gives the same ID too; `v0.1.0` and
older can pick up file times from another commit's cached build.

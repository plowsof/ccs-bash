# When something is wrong

Logs: `/var/log/ccs-bash.log`, and with [setup](setup.md) step 7
`journalctl -u ccs-bash -u ccs-wallet-rpc`.

| In the log | Meaning |
|---|---|
| `curl: (22) ... error: 401` | Wrong wallet login. Try `curl --digest -u 'ccs:<rpc password>' http://127.0.0.1:18082/json_rpc -d '{"jsonrpc":"2.0","id":0,"method":"get_version"}'`. A key given twice in the config (even empty) wins. |
| `main address is not WALLET_ADDRESS` | Another wallet on that port. Nothing written. |
| `donations at subaddress ..., which proposals.csv doesn't have` | The state file lacks entries, see [Moving from ccs-back](migrating.md) step 3. Nothing written. |
| `could not fetch ideas from GitLab` | GitLab is down; the old Ideas list stays. |
| `skipping <file>: ...` | That proposal's frontmatter can't be read (reason follows); it's left off. |
| `ignoring tags of <file>: ...` | Its `tags:` can't be read (reason follows): the proposal shows, without tags. A list of up to 5, each up to 40 bytes. |
| `error: <name>: 1 of 2 maintainer signatures` (build) | A StageX pin lacks two trusted signatures. Don't work around it: refresh the [keys](image.md#signatures) if StageX added a maintainer, else ask StageX. |

Inside the image there is only bash and the busybox applets in `container/busybox-applets`.
To look around: `docker run --rm -it --entrypoint bash ccs-bash` (with `ccs-bash-run`'s `-v`s).

Another image ID than CI's? Rebuild with `NO_CACHE=1 container/build.sh`. (Builds of `v0.1.0`
and older could pick up file times from another commit's cache.)

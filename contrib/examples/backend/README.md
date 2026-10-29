# The backend's files, filled in for ccs.getmonero.org

Each file here is at the path it goes to on the backend, filled in with what is public for
ccs.getmonero.org (the wallet's main address, the proposals repository, the ports, the
signed list's signers). What is yours, a password, a machine's address, the IRC bot's URL, is
`<…>`, with a line above saying where it comes from. For the backend in Docker
([docker](../../../docs/docker.md)); the host setup ([setup](../../../docs/setup.md)) uses the same
files but the `.env`, and `RPC_URL` on `127.0.0.1`.

After [setup](../../../docs/setup.md) steps 1-2 made the users and folders, as root:

```
cd /opt/ccs-bash/contrib/examples/backend
install -g ccs -m 640 etc/ccs/ccs.conf etc/ccs/alert.conf /etc/ccs/
install -m 644 etc/ccs/trusted-signers /etc/ccs/
install -g ccs-wallet -m 640 etc/ccs-wallet/wallet-rpc.conf /etc/ccs-wallet/
install -d -m 755 /etc/ccs-front && install -m 644 etc/ccs-front/list-signers /etc/ccs-front/
install -m 600 opt/ccs-bash/contrib/docker/backend/.env /opt/ccs-bash/contrib/docker/backend/
```

then fill in every `<…>`, and `ccs config:check` until nothing fails. It looks at each file
setup needs (these, and the signed list, the push and backup keys), their owners and modes, that
they agree (`RPC_URL`'s port and login are `wallet-rpc.conf`'s; `.env`'s `WALLET_PORT` is the
wallet's; nothing the containers can't reach on 127.0.0.1), and that they answer: the wallet,
with `WALLET_ADDRESS`, view-only; the forge; the web server and the backup machine, their host
keys known; the images, attested in ccs-sigs. It changes nothing and prints no password or key.

| File | Owner, mode | What is yours |
|---|---|---|
| `/etc/ccs/ccs.conf` | root:ccs 640 | `RPC_PASSWORD` |
| `/etc/ccs-wallet/wallet-rpc.conf` | root:ccs-wallet 640 | the wallet's `password`, `daemon-address`, the RPC password in `rpc-login` |
| `/etc/ccs/alert.conf` | root:ccs 640 | `ALERT_URL` (the IRC bot), `WATCH_PROXY` |
| `/etc/ccs/trusted-signers` | root 644 | the attesters you trust |
| `/etc/ccs-front/list-signers` | root 644 | nothing: binaryFate and luigi1111 |
| `/opt/ccs-bash/contrib/docker/backend/.env` | root 600 | the image IDs, the users' uid:gid, the web server and backup machine |

Not here, as they are made, not written: the wallet files (handover, 1), the signed list and its
`.asc`, `.key.asc`, `.pin`, `.viewkey` in `/etc/ccs-front/` (handover, 4), the push key and the
web server's host key in `/var/lib/ccs/.ssh/` (two-machines), the backup key and the backup
machine's host key in `/etc/ccs/backup/` (docker, setting it up, 2).

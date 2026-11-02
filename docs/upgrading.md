# Upgrading

Steps a release needs **once**, on top of [deploying a set](handover.md#deploying-a-set-the-docker-setup).
Newest first. Upgrading across several releases: do each step listed between the running release
and the new one, oldest first. A release not listed needs none.

## ccs-bash v0.2.41 (2026-11-02): the push is a tar

`contrib/ccs-push` and the gate's `ccs-check receive`; no rsync on either machine. The new gate
refuses the old backend's rsync push, and the old gate the new backend's tar, so pushes fail from
step 3 until step 5 (the live site stays as it is; past 15 minutes the heartbeat tells IRC, then
that they arrive again). Do the backend right after the web server. The first push sends every
file (no record yet of what the gate took).

## ccs-bash v0.2.41 and ccs-front-bash v0.1.26 (2026-11-02): the QR codes are the list's files

The list's QR codes, made from the installed list with `tools/make-qr.sh` from ccs-front-bash's
attested commit on a machine with qrencode (your own, or the backend's host), then checked with
the `.pin` from this repository's `subaddresses/<wallet>/` (the same list, a third line `qr …`;
[the signed list](signed-list.md)):

```
install -d -m 700 /tmp/l && cp /etc/ccs-front/subaddresses.txt* /tmp/l/ && cp /opt/ccs-bash/subaddresses/<wallet>/subaddresses.txt.pin /tmp/l/
/opt/ccs-front-bash/tools/make-qr.sh /tmp/l/subaddresses.txt          # .qr/ and .qr.sha256, about 30 s
SIGNER_KEYS=<the signer's key> /opt/ccs-front-bash/tools/verify-subaddresses.sh /tmp/l/subaddresses.txt /etc/ccs-front/list-signers <WALLET_ADDRESS>
```

OK: the new `.pin` and `.qr.sha256` go to `/etc/ccs-front/` and `/etc/ccs-gate/` (root, 644),
`subaddresses.txt.qr/` to `/etc/ccs-front/` only (755); copy each file into place, the pin last
(the old releases ignore the `qr` line and the new files). Without them the new gate refuses every
push and the new ccs-front-bash stops. Then the web server's nginx: `img-src 'self'` (no `data:`,
[two machines](two-machines.md)), once the backend's new release is live.

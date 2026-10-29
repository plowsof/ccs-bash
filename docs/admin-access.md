# Admin access to the machines

For the deploy team: how you yourselves reach the backend, the web server and the backup
machine. The CCS's own connections are already locked down (the push and backup keys work only
from the backend's address and only run the gate or the backup receiver: [two
machines](two-machines.md)); this is about the admin's ssh, which the design leaves to you.

## Why it matters

The two machines watch each other ([the design](design.md#what-one-compromise-can-and-cant-do)): a
taken-over web server is seen by the backend's ccs-watch, a taken-over backend by the web server's
gate. That holds against one machine at a time. It doesn't hold against one flaw that opens both
at once, and the likeliest is the admin's own way in: the same sshd, open to the whole internet,
on every machine. A flaw in sshd before it checks any key (regreSSHion, CVE-2024-6387, gave root
that way) would open them all together, and nothing would be left to raise the alarm.

A key-only sshd stops guessing and stolen passwords, not that. A rule per user (`from=` on your
key, `AllowUsers you@<ip>`) doesn't either: sshd reads the user only after the part such a flaw is
in. Only something in front of sshd does: the firewall, or a VPN.

## The options

| | You get in | Your address changes | Stops a flaw in sshd before its key check | What it adds to protect |
|---|---|---|---|---|
| **A. WireGuard** (recommended) | connect the VPN, then ssh over it | no effect | yes: only a VPN key reaches sshd | the VPN keys; WireGuard itself (small, silent to anyone without a key) |
| **B. Allowlist** in the firewall | from listed addresses only | locked out until you add the new one | yes | the list |
| **C. Jump host** | ssh to one small machine with a fixed address; the others allow only it | no effect | yes, for the others | the jump host: its sshd is open to everyone |

A suits a team whose home addresses change; B one with fixed addresses (an office, a VPN of
their own); C a team that already runs a bastion.

## Before any of them: a way back in

Every one of these can lock you out (a wrong rule, a VPN that won't start, an address that
changed). Know first how to reach each machine without ssh, and try it once:

- **Hetzner** (the testnet's backend): Robot, the Rescue system (boots a rescue image with your
  key; mount the disk, undo the change), or a KVM console on request.
- **OVH** (the testnet's web server): the control panel's rescue mode, or its KVM/IPMI console.
- **A cloud VM:** its serial or web console.

From the console, `ufw disable` undoes any of the firewall steps below. Keep a second admin's key
(or a second VPN peer, a phone) on each machine too.

## A. WireGuard

On each machine, as root (`apt install wireguard`; the addresses are examples, one /24 for the
team):

```
umask 077; wg genkey | tee /etc/wireguard/wg0.key | wg pubkey > /etc/wireguard/wg0.pub
cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
Address = 10.77.0.1/24              # 10.77.0.1 the backend, .2 the web server, .3 the backup machine
ListenPort = 51820
PrivateKey = $(cat /etc/wireguard/wg0.key)

[Peer]                              # one block for each admin's laptop
PublicKey = <the laptop's public key>
AllowedIPs = 10.77.0.10/32
EOF
systemctl enable --now wg-quick@wg0
ufw allow 51820/udp
ufw allow in on wg0 to any port 22 proto tcp     # the sshd port, over the VPN
```

On each laptop, a peer for each machine (`Endpoint = <machine>:51820`,
`AllowedIPs = 10.77.0.1/32` and so on, `PersistentKeepalive = 25`), then `ssh you@10.77.0.1`.

Then, and only once each admin has logged in over the VPN, and better after some days of using
it: `ufw delete allow 22/tcp` (the old open rule; the sshd port's, whichever it is). sshd keeps
listening on every address: the firewall is what keeps the rest out, so a VPN that comes up late
after a reboot doesn't stop sshd from starting (binding sshd to the VPN's address would).

## B. Allowlist

```
ufw allow from <your address> to any port 22 proto tcp comment 'admin'   # each, IPv6 too
ufw delete allow 22/tcp                                                   # then the open rule
```

Check before closing that `ufw status` lists every admin's address, and keep the console handy:
the first time an address changes, that's the way back in.

## C. Jump host

A small machine with a fixed address, its sshd key-only and kept up to date; on the others, B with
only its address. Its own sshd is open to everyone, so it carries the risk the others shed: keep
nothing on it but the admins' keys, and nothing of the CCS.

## Risks, whichever you pick

- **Lockout:** the console, above. Change one machine at a time, and test from a second session
  before closing the first.
- **Docker and ufw:** a port Docker publishes (`-p`, `ports:`) is let in by Docker's own rules,
  ahead of ufw's, whatever ufw says. The CCS composes use the host's network, so ufw does apply
  to them (2223, 2224: the backend's address only); check any other service on the machine with
  `iptables -L DOCKER -n` or by trying it from outside.
- **IPv6:** a rule for IPv4 only leaves IPv6 open; `ufw status` shows both.
- **The VPN's keys** are as good as ssh keys: a laptop that's lost loses its peer block.
- **Everything else open:** an allowlist for ssh does nothing for another service the machine
  runs (a monerod, a database, a web panel). The design assumes dedicated machines: the backend
  open to nothing, the web server to 80, 443 and the backend.

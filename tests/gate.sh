#!/usr/bin/env bash
# The web server's gate (contrib/ccs-receive, docs/two-machines.md): a web server set up as
# documented and a backend, in containers. A good push goes live; a push with an address that is
# neither the wallet's nor allowed, or a list that isn't the pinned one, leaves the live site as it
# was and says why. Needs docker and network.
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
name=ccs-gate-test
net=172.30.98
web=$net.2 backend=$net.3

cleanup() {
    docker rm -f "$name-web" "$name-backend" > /dev/null 2>&1 || true
    docker network rm "$name" > /dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup

# Debian 12, as in the docs (the same pinned image as tests/rrsync.sh)
docker buildx build -q --load -t "$name" - > /dev/null <<IMG
FROM debian@sha256:7ff6ba31527b9e336162fa061746c366c4b2032f4d2cff2078bea43f78efe3f8
RUN apt-get update -q && apt-get install -y -q --no-install-recommends openssh-server openssh-client rsync python3 \
    && rm -rf /var/lib/apt/lists/*
IMG
docker network create --subnet "$net.0/24" "$name" > /dev/null
for h in web:$web backend:$backend; do
    docker run -d --name "$name-${h%%:*}" --network "$name" --ip "${h#*:}" "$name" sleep infinity > /dev/null
done
on() { local h=$1; shift; docker exec "$name-$h" bash -c "$@"; }

# a wallet of three subaddresses, and the General Fund allowed
addr() { printf '%s%094d' "${2:-9}" "$1" | tr 0 1; }   # 95 base58 characters (no 0)
list=$(for i in 0 1 2; do echo "$i $(addr "$i")"; done)
fund=$(addr 7 8)

on backend 'mkdir -p ~/.ssh && ssh-keygen -q -t ed25519 -N "" -f ~/.ssh/id_ed25519'
key=$(on backend 'cat ~/.ssh/id_ed25519.pub')
docker cp "$here/../contrib/ccs-receive" "$name-web:/usr/local/bin/ccs-receive"
on web "
    chown root:root /usr/local/bin/ccs-receive && chmod 755 /usr/local/bin/ccs-receive
    useradd --system --create-home --shell /bin/sh ccs-data
    install -d -o ccs-data -m 755 /var/lib/ccs-data /var/lib/ccs-staging
    install -d -m 755 /etc/ccs-gate
    printf '%s\n' '$list' > /etc/ccs-gate/subaddresses.txt
    printf 'sha256 %s\nkey %040d\n' \"\$(sha256sum < /etc/ccs-gate/subaddresses.txt | cut -d' ' -f1)\" 0 > /etc/ccs-gate/subaddresses.txt.pin
    printf '%s  # the General Fund\n' '$fund' > /etc/ccs-gate/allowed
    chmod 644 /etc/ccs-gate/*
    install -d -m 755 ~ccs-data/.ssh
    echo 'from=\"$backend\",command=\"/usr/local/bin/ccs-receive\",restrict $key' > ~ccs-data/.ssh/authorized_keys
    chmod 644 ~ccs-data/.ssh/authorized_keys
    mkdir -p /run/sshd && ssh-keygen -A && /usr/sbin/sshd
"
on backend "echo '$web $(on web 'cat /etc/ssh/ssh_host_ed25519_key.pub')' > ~/.ssh/known_hosts"

status=0
ok() { echo "ok   $1"; }
fail() { echo "FAIL $1"; status=1; }
# site N ADDRESS: the backend's site, version N, a donation box with ADDRESS and the General Fund
# in the footer, plus a QR code whose base64 has an address-shaped run in it
site() {
    on backend "rm -rf /out && mkdir -p /out/proposals && echo 'v$1' > /out/version.txt
        printf '<a href=\"monero:%s\">QR</a><div class=\"address\">%s</div><img src=\"data:image/png;base64,ab+%s/cd\">\n<p class=\"address\">%s</p>\n' \
            '$2' '$2' '$(addr 5 Z)' '$fund' > /out/proposals/p.html
        echo '[{\"address\": \"$2\"}]' > /out/projects.json"
}
push() { on backend "rsync -a --delay-updates -e 'ssh -o BatchMode=yes -o StrictHostKeyChecking=yes' /out/ ccs-data@$web: 2>&1"; }
live() { on web 'cat /var/lib/ccs-data/version.txt 2> /dev/null'; }

site 1 "$(addr 1)"
if out=$(push) && [[ $(live) == v1 ]]; then ok "a push with the wallet's addresses goes live"; else echo "$out"; fail "a good push"; fi

site 2 "$(addr 9 B)"
if ! out=$(push) && [[ $(live) == v1 && $out == *"not the wallet's nor allowed"* && $out == *"proposals/p.html: $(addr 9 B)"* ]]; then
    ok "an address that isn't the wallet's: refused, the live site unchanged, the backend told which and where"
else
    echo "$out"; fail "a foreign address"
fi

site 3 "$(addr 2)"
on backend "printf 'pay %s here\n' '$(addr 8 A)' > /out/proposals/sneaky.html"
if ! push > /dev/null && [[ $(live) == v1 ]]; then ok "an address anywhere in a page is checked, not only the donation box"; else fail "a hidden address"; fi

site 4 "$(addr 2)"
if push > /dev/null && [[ $(live) == v4 ]]; then ok "the next good push goes live again"; else fail "recovery"; fi

on web "echo '3 $(addr 3)' >> /etc/ccs-gate/subaddresses.txt"
site 5 "$(addr 3)"
if ! out=$(push) && [[ $(live) == v4 && $out == *"is not the list"*".pin names"* ]]; then ok "a list that isn't the pinned one: every push refused"; else echo "$out"; fail "a changed list"; fi

# rrsync's limits still hold through the gate: no deleting, nothing outside its folder
on web "echo keep > /var/lib/ccs-data/keep.txt"
site 6 "$(addr 2)"
on backend "rsync -a --delete -e 'ssh -o BatchMode=yes' /out/ ccs-data@$web: > /dev/null 2>&1" || true
on backend "echo x > /tmp/x && rsync -e 'ssh -o BatchMode=yes' /tmp/x ccs-data@$web:../../../tmp/escaped > /dev/null 2>&1" || true
if [[ $(on web 'cat /var/lib/ccs-data/keep.txt') == keep ]] && ! on web 'test -e /tmp/escaped || test -e /var/lib/escaped'; then
    ok "no deleting and nothing outside the folder, through the gate too"
else
    fail "rrsync's limits"
fi

# the key still runs nothing but the gate
if ! on backend "ssh -o BatchMode=yes ccs-data@$web 'cat /etc/passwd' 2>&1" | grep -q root; then ok "the key runs nothing else"; else fail "the key ran a command"; fi
exit "$status"

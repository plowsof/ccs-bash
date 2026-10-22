#!/usr/bin/env bash
# docs/two-machines.md, attacked from a taken-over wallet machine: web server (as documented),
# wallet machine, another machine, in containers. Needs docker and network.
# --loose keeps only rrsync and its folder: then the checks for the other restrictions must fail.
set -euo pipefail
name=ccs-rrsync-test
net=172.30.99
web=$net.2 wallet=$net.3 other=$net.4

cleanup() {
    docker rm -f "$name-web" "$name-wallet" "$name-other" > /dev/null 2>&1 || true
    docker network rm "$name" > /dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup

# The web server is Debian 12, as in the docs: its sshd and rsync (3.2.7, rrsync
# included), on a pinned debian:bookworm-slim.
docker buildx build -q --load -t "$name" - > /dev/null <<EOF
FROM debian@sha256:7ff6ba31527b9e336162fa061746c366c4b2032f4d2cff2078bea43f78efe3f8
RUN apt-get update -q && apt-get install -y -q --no-install-recommends openssh-server openssh-client rsync python3 \
    && rm -rf /var/lib/apt/lists/*
EOF
docker network create --subnet "$net.0/24" "$name" > /dev/null
for h in web:$web wallet:$wallet other:$other; do
    docker run -d --name "$name-${h%%:*}" --network "$name" --ip "${h#*:}" "$name" sleep infinity > /dev/null
done
on() { local h=$1; shift; docker exec "$name-$h" bash -c "$@"; }

# The wallet machine's key; the other machine has a copy of it (only from= keeps it out).
on wallet 'mkdir -p ~/.ssh && ssh-keygen -q -t ed25519 -N "" -f ~/.ssh/id_ed25519'
key=$(on wallet 'cat ~/.ssh/id_ed25519.pub')
docker exec "$name-wallet" cat /root/.ssh/id_ed25519 | docker exec -i "$name-other" bash -c 'mkdir -p ~/.ssh && cat > ~/.ssh/id_ed25519 && chmod 600 ~/.ssh/id_ed25519'

# The web server, as in the docs.
line="from=\"$wallet\",command=\"rrsync -wo -no-del -munge /var/lib/ccs-data\",restrict $key"
[[ ${1:-} == --loose ]] && line="command=\"rrsync /var/lib/ccs-data\" $key"
on web "
    useradd --system --create-home --shell /bin/sh ccs-data
    install -d -o ccs-data -m 755 /var/lib/ccs-data
    install -d -m 755 ~ccs-data/.ssh
    echo '$line' > ~ccs-data/.ssh/authorized_keys
    chmod 644 ~ccs-data/.ssh/authorized_keys
    mkdir -p /run/sshd && ssh-keygen -A && /usr/sbin/sshd
    echo secret > /root/secret
"
hostkey=$(on web 'cat /etc/ssh/ssh_host_ed25519_key.pub')
for h in wallet other; do on "$h" "echo '$web $hostkey' > ~/.ssh/known_hosts"; done
keyline=$(on web 'sha256sum ~ccs-data/.ssh/authorized_keys')

status=0
ok() { echo "ok   $1"; }
fail() { echo "FAIL $1"; status=1; }
ssh_opts="ssh -o BatchMode=yes -o StrictHostKeyChecking=yes"
push() { on "${2:-wallet}" "cd /out && rsync $1 -e '$ssh_opts' 2>&1"; }

# The normal push from the docs.
on wallet 'mkdir -p /out && echo "[1]" > /out/proposals.json && echo "[2]" > /out/projects.json'
push "-a --delay-updates /out/ ccs-data@$web:" > /dev/null
if [[ $(on web 'cat /var/lib/ccs-data/proposals.json') == '[1]' ]]; then ok "the documented push works"; else fail "the documented push"; fi

out=$(on wallet "$ssh_opts -tt ccs-data@$web id 2>&1" || true)
if [[ $out != *uid=* ]]; then ok "no commands, no shell"; else fail "ran a command: $out"; fi

out=$(on wallet "$ssh_opts -W 127.0.0.1:22 ccs-data@$web < /dev/null 2>&1" || true)
if [[ $out != *SSH-2.0* ]]; then ok "no port forwarding"; else fail "port forwarding works"; fi

push "ccs-data@$web:proposals.json /tmp/back" > /dev/null || true
if on wallet '[[ ! -e /tmp/back ]]'; then ok "nothing can be read back"; else fail "read a file back"; fi

for dest in ../escaped /tmp/escaped /home/ccs-data/.ssh/authorized_keys ../../../home/ccs-data/.ssh/escaped; do
    push "proposals.json ccs-data@$web:$dest" > /dev/null || true
done
if on web '! find / -xdev -path /var/lib/ccs-data -prune -o -name escaped -print | grep -q .' \
    && [[ $(on web 'sha256sum ~ccs-data/.ssh/authorized_keys') == "$keyline" ]]; then
    ok "nothing written outside the folder (.., absolute paths, its own key)"
else
    fail "wrote outside the folder"
fi

# Options that name a second folder on the receiving side.
on wallet 'mkdir -p /etc-copy && cp /etc/passwd /etc-copy/passwd'
for opt in "-M--temp-dir=/tmp/escaped" "--partial-dir=/tmp/escaped" "-b --backup-dir=/tmp/escaped" \
    "-M--log-file=/tmp/escaped" "--link-dest=/etc" "--copy-dest=/etc" "--compare-dest=/root"; do
    push "-a $opt /out/proposals.json /etc-copy/passwd ccs-data@$web:" > /dev/null || true
done
if on web '! find / -xdev -path /var/lib/ccs-data -prune -o -name escaped -print | grep -q . \
           && [[ $(stat -c %i /etc/passwd) != $(stat -c %i /var/lib/ccs-data/passwd 2> /dev/null) ]]'; then
    ok "temp/partial/backup/log/link/copy/compare folders stay inside or are refused"
else
    fail "an option reached outside the folder"
fi

on wallet 'mkdir -p /empty'
push "-a --delete /empty/ ccs-data@$web:" > /dev/null || true
push "-a -M--delete-during /empty/ ccs-data@$web:" > /dev/null || true
push "-a --remove-source-files ccs-data@$web:proposals.json /tmp/x" > /dev/null || true
if on web '[[ -e /var/lib/ccs-data/proposals.json && -e /var/lib/ccs-data/projects.json ]]'; then ok "nothing deleted"; else fail "files were deleted"; fi

on wallet 'mkdir -p /evil && ln -s /root/secret /evil/projects.json && ln -s ../../../root/secret /evil/rel.json'
push "-a /evil/ ccs-data@$web:" > /dev/null || true
if on web 'for f in projects.json rel.json; do [[ $(cat /var/lib/ccs-data/$f 2> /dev/null) != secret ]] || exit 1; done'; then
    ok "uploaded symlinks don't point anywhere (-munge)"
else
    fail "an uploaded symlink reads another file"
fi

on other 'mkdir -p /out && echo "[3]" > /out/projects.json'
out=$(push "-a /out/ ccs-data@$web:" other || true)
if [[ $out == *"Permission denied"* || $out == *"connection unexpectedly closed"* ]]; then ok "the key doesn't work from another machine"; else fail "key works from another machine: $out"; fi

exit "$status"

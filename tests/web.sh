#!/usr/bin/env bash
# The web server compose (contrib/docker/web), attacked from the backend's keys: its gate and
# backup sshd run from the gate's image (CCS_GATE_IMAGE, default ccs-gate) as compose.yml runs
# them (its capabilities, read-only, no-new-privileges, command: read from docker compose config),
# on a test network instead of the host's, beside a backend and another machine with a copy of its
# keys. The push key runs only the gate, the backup key only the backup receiver, each from the
# backend only; no shell, terminal or forwarding; nothing but keys. Needs docker and network.
set -uo pipefail
here=$(dirname "$(readlink -f "$0")")
img=${CCS_GATE_IMAGE:-ccs-gate}
name=ccs-web-test net=172.30.96
web=$net.2 backend=$net.3 other=$net.4
debian=debian@sha256:7ff6ba31527b9e336162fa061746c366c4b2032f4d2cff2078bea43f78efe3f8
status=0
ok() { echo "ok   $1"; }
fail() { echo "FAIL $1"; status=1; }

cleanup() {
    docker container rm -f "$name-gate" "$name-backup" "$name-backend" "$name-other" > /dev/null 2>&1
    docker network rm "$name" > /dev/null 2>&1
    docker volume rm "$name-keys" "$name-ak" "$name-backups" > /dev/null 2>&1
    return 0
}
trap cleanup EXIT
cleanup

# each service's settings, as compose.yml has them
env=$(mktemp)
printf 'CCS_GATE_IMAGE=%s\nCCS_DATA_UID=997:997\nCCS_BACKUP_UID=998:998\n' "$img" > "$env"
conf=$(docker compose -f "$here/../contrib/docker/web/compose.yml" --env-file "$env" --profile backup config --format json) || { echo "FAIL compose config"; exit 1; }
rm -f "$env"
# flags SERVICE: its docker run options (those that harden it) and command
flags() {
    jq -r --arg s "$1" '.services[$s] | ((.cap_drop // [])[] | "--cap-drop=\(.)"), ((.cap_add // [])[] | "--cap-add=\(.)"),
        (if .read_only then "--read-only" else empty end), ((.security_opt // [])[] | "--security-opt=\(.)"),
        ((.tmpfs // [])[] | "--tmpfs=\(.)"), "--user=\(.user)"' <<<"$conf"
}
cmd() { jq -r --arg s "$1" '.services[$s].command[]' <<<"$conf"; }

docker network create --subnet "$net.0/24" "$name" > /dev/null
for v in keys ak backups; do docker volume create "$name-$v" > /dev/null; done
# init, as compose.yml's: the host key and passwd in the keys folder
docker run --rm --network none -u 0:0 -e CCS_DATA_UID=997:997 -e CCS_BACKUP_UID=998:998 -v "$name-keys:/etc/ccs-ssh/keys" \
    --entrypoint /usr/local/bin/ccs-web-init "$img" > /dev/null || { echo "FAIL init"; exit 1; }
# the backend and another machine: Debian, ssh and rsync
for h in backend:$backend other:$other; do
    docker run -d --name "$name-${h%%:*}" --network "$name" --ip "${h#*:}" "$debian" sleep infinity > /dev/null
done
for h in backend other; do
    docker exec "$name-$h" bash -c 'apt-get update -qq > /dev/null && apt-get install -qq -y --no-install-recommends openssh-client rsync > /dev/null 2>&1' \
        || { echo "FAIL apt on $h"; exit 1; }
done
on() { local h=$1; shift; docker exec "$name-$h" bash -c "$@"; }
on backend 'mkdir -p ~/.ssh && ssh-keygen -q -t ed25519 -N "" -f ~/.ssh/push && ssh-keygen -q -t ed25519 -N "" -f ~/.ssh/backup'
docker exec "$name-backend" tar -C /root -c .ssh | docker exec -i "$name-other" tar -C /root -x
push=$(on backend 'cat ~/.ssh/push.pub') backup=$(on backend 'cat ~/.ssh/backup.pub')
# the key files as the host setup has them (root's), and a backup folder of ccs-backup's
docker run --rm --network none -u 0:0 -v "$name-ak:/ak" -v "$name-backups:/b" --entrypoint bash "$img" -c "
    echo 'from=\"$backend\",command=\"/usr/local/bin/ccs-receive\",restrict $push' > /ak/ccs-data
    echo 'from=\"$backend\",restrict,command=\"/usr/local/bin/ccs-backup-receive\" $backup' > /ak/ccs-backup
    chmod 644 /ak/* && chmod 755 /ak && chown 998:998 /b && chmod 700 /b"
mapfile -t gate_flags < <(flags gate) && mapfile -t gate_cmd < <(cmd gate)
mapfile -t backup_flags < <(flags backup) && mapfile -t backup_cmd < <(cmd backup)
docker run -d --name "$name-gate" --network "$name" --ip "$web" "${gate_flags[@]}" \
    -v "$name-keys:/etc/ccs-ssh/keys:ro" -v "$name-ak:/etc/ccs-ssh/authorized_keys:ro" "$img" "${gate_cmd[@]}" > /dev/null
docker run -d --name "$name-backup" --network "container:$name-gate" "${backup_flags[@]}" \
    -v "$name-keys:/etc/ccs-ssh/keys:ro" -v "$name-ak:/etc/ccs-ssh/authorized_keys:ro" -v "$name-backups:/var/lib/ccs-backup" \
    "$img" "${backup_cmd[@]}" > /dev/null
hostkey=$(docker run --rm --network none -v "$name-keys:/k:ro" --entrypoint cat "$img" /k/ssh_host_ed25519_key.pub)
for h in backend other; do on "$h" "printf '[%s]:2223 %s\n[%s]:2224 %s\n' $web '$hostkey' $web '$hostkey' > ~/.ssh/known_hosts"; done
sleep 2
s() { local h=$1 key=$2 port=$3; shift 3; on "$h" "timeout 30 ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o IdentitiesOnly=yes -i ~/.ssh/$key -p $port $* 2>&1"; }

if [[ $(jq -r '.services.gate.cap_add | sort | join(",")' <<<"$conf") == "SETGID,SETUID,SYS_CHROOT" && $(docker inspect "$name-gate" --format '{{.HostConfig.ReadonlyRootfs}} {{.HostConfig.CapDrop}} {{.HostConfig.SecurityOpt}}') == "true [ALL] [no-new-privileges:true]" ]]; then
    ok "sshd as compose.yml runs it: read-only, every capability dropped but SETUID, SETGID and SYS_CHROOT, no-new-privileges"
else fail "the containers' settings: $(docker inspect "$name-gate" --format '{{.HostConfig.ReadonlyRootfs}} {{.HostConfig.CapDrop}} {{.HostConfig.CapAdd}} {{.HostConfig.SecurityOpt}}')"; fi

# the backup key: a file goes to the backup receiver, kept
out=$(on backend "printf '\"a.md\",\"\",\"\",\"\",\"\"\n' | timeout 30 ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o IdentitiesOnly=yes -i ~/.ssh/backup -p 2224 ccs-backup@$web 2>&1")
kept=$(docker run --rm --network none -u 998:998 -v "$name-backups:/b:ro" --entrypoint bash "$img" -c 'ls /b | grep -c "^proposals-"')
if [[ $out == *"kept proposals-"* && $kept == 1 ]]; then ok "the backup key: its file kept by ccs-backup-receive"; else fail "the backup push: $out ($kept kept)"; fi

# the push key runs the gate whatever is asked (it refuses: no design, no list here), never a shell
out=$(s backend push 2223 "ccs-data@$web id")
if [[ $out != *uid=* && $out == *ccs-gate* ]]; then ok "the push key: only the gate runs, whatever command is asked (no shell)"; else fail "the push key ran: $out"; fi
out=$(s backend push 2223 "-tt ccs-data@$web /bin/bash -i < /dev/null")
if [[ $out != *uid=* && $out != *'$ '* && $out != *'# '* ]]; then ok "no terminal, no interactive shell"; else fail "a shell: $out"; fi
out=$(s backend backup 2224 "ccs-backup@$web id < /dev/null")
if [[ $out != *uid=* ]]; then ok "the backup key: only the backup receiver runs (no shell)"; else fail "the backup key ran: $out"; fi

# forwarding, both ports
f1=$(s backend push 2223 "-W 127.0.0.1:2224 ccs-data@$web < /dev/null")
f2=$(s backend backup 2224 "-W 127.0.0.1:2223 ccs-backup@$web < /dev/null")
if [[ $f1 != *SSH-2.0* && $f2 != *SSH-2.0* ]]; then ok "no forwarding (-W) through either"; else fail "forwarding: $f1 / $f2"; fi

# each key for its own account and port only; nothing but keys; root nowhere
a=$(s backend push 2224 "ccs-backup@$web true < /dev/null") b=$(s backend backup 2223 "ccs-data@$web true < /dev/null")
c=$(s backend push 2223 "root@$web true < /dev/null") d=$(on backend "timeout 30 ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o PubkeyAuthentication=no -p 2223 ccs-data@$web true 2>&1")
if [[ $a == *"Permission denied"* && $b == *"Permission denied"* && $c == *"Permission denied"* && $d == *"Permission denied (publickey)"* ]]; then
    ok "each key works only on its own account (the other port's refuses it), root refused, no password or keyboard login offered"
else fail "accounts: $a / $b / $c / $d"; fi

# from=: a copy of the keys on another machine is refused
a=$(s other push 2223 "ccs-data@$web true < /dev/null") b=$(on other "printf 'x\n' | timeout 30 ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o IdentitiesOnly=yes -i ~/.ssh/backup -p 2224 ccs-backup@$web 2>&1")
if [[ $a == *"Permission denied"* && $b == *"Permission denied"* ]]; then ok "from=: the keys don't work from another machine"; else fail "from another machine: $a / $b"; fi

# what sshd says, in docker's log (journald's, in compose.yml)
if docker logs "$name-gate" 2>&1 | grep -q "Accepted publickey for ccs-data from $backend"; then ok "sshd logs to docker (journald in compose.yml)"; else fail "sshd's log"; fi
exit "$status"

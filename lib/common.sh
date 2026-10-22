# shellcheck shell=bash
# Logging, config and file helpers shared by the other lib/ files.

now_utc() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
log() { printf '%s %s\n' "$(date -u '+%F %T')" "$*" >&2; }
die() { log "error: $*"; exit 1; }

# Source the config and check the required settings. It pins the wallet (WALLET_ADDRESS),
# so ccs-bash must not be able to write it.
load_config() {
    [[ -r $1 ]] || die "cannot read config $1"
    [[ ! -w $1 ]] || die "config $1 is writable by $(id -un 2> /dev/null || id -u): it pins the wallet, so it must be owned by root and only readable by the (unprivileged) user running ccs-bash"
    # shellcheck source=/dev/null
    source "$1"
    : "${RPC_URL:?} ${REPOSITORY_URL:?} ${PROPOSALS_DIR:?} ${STATE_DIR:?} ${OUTPUT_DIR:?} ${WALLET_ADDRESS:?}"
    [[ $WALLET_ADDRESS =~ ^[0-9A-Za-z]{95}$ ]] || die "WALLET_ADDRESS must be the wallet's main address (95 characters)"
    RPC_USER=${RPC_USER:-}
    RPC_PASSWORD=${RPC_PASSWORD:-}
    MIN_CONFIRMATIONS=${MIN_CONFIRMATIONS:-10}
    [[ $MIN_CONFIRMATIONS =~ ^[0-9]+$ ]] || die "MIN_CONFIRMATIONS must be a number"
}

# atomic_write FILE COMMAND...: replace FILE with COMMAND's output if it succeeds and prints
# something (temp file, sync, rename: never half a file, a failure keeps the old one).
atomic_write() {
    local out=$1 tmp
    shift
    (($#)) || { log "error: atomic_write $out: no command"; return 1; }
    tmp=$(mktemp "$out.XXXXXX") || return 1
    if "$@" > "$tmp" && [[ -s $tmp ]] && chmod 644 "$tmp" && sync "$tmp" && mv -f "$tmp" "$out"; then
        return 0
    fi
    rm -f "$tmp"
    log "error: could not write $out, keeping the old one"
    return 1
}

# Filenames come from the repo and GitLab: plain names only. No directories, control
# characters, hidden files or backslashes (jq's @tsv would double them).
safe_filename() {
    [[ $1 == *.md && $1 != .* && $1 != */* && $1 != *[[:cntrl:]]* && $1 != *\\* ]]
}

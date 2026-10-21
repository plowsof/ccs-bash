# shellcheck shell=bash
# Logging, config and file helpers shared by the other lib/ files.

log() { printf '%s %s\n' "$(date -u '+%F %T')" "$*" >&2; }
die() { log "error: $*"; exit 1; }

# Source the config file and check the required settings are there.
load_config() {
    [[ -r $1 ]] || die "cannot read config $1"
    # shellcheck source=/dev/null
    source "$1"
    : "${RPC_URL:?} ${REPOSITORY_URL:?} ${PROPOSALS_DIR:?} ${STATE_DIR:?} ${OUTPUT_DIR:?}"
    RPC_USER=${RPC_USER:-}
    RPC_PASSWORD=${RPC_PASSWORD:-}
    MIN_CONFIRMATIONS=${MIN_CONFIRMATIONS:-10}
    [[ $MIN_CONFIRMATIONS =~ ^[0-9]+$ ]] || die "MIN_CONFIRMATIONS must be a number"
}

# Write stdin to file $1 via a temp file, so readers never see half a file.
atomic_write() {
    local tmp
    tmp=$(mktemp "$1.XXXXXX") || return 1
    if cat > "$tmp" && chmod 644 "$tmp" && mv -f "$tmp" "$1"; then
        return 0
    fi
    rm -f "$tmp"
    return 1
}

# Filenames come from the repo and from GitLab MRs, so only accept plain
# names: no directories, no control characters, no hidden files.
safe_filename() {
    [[ $1 == *.md && $1 != .* && $1 != */* && $1 != *[[:cntrl:]]* ]]
}

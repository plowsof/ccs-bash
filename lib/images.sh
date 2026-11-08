# shellcheck shell=bash
# Proposal images. They live in the proposals repository at images/<proposal>/<file>
# (my-proposal.md uses images/my-proposal/chart.png), and the .md shows them with
# markdown like ![...](images/<proposal>/<file>). The proposals CI requires this layout.
# Images shown by proposals on the site are copied into OUTPUT_DIR/images/ and listed in
# OUTPUT_DIR/images.json as {"images/<proposal>/<file>": "<proposal>/<file>"}.
# ccs-front-bash then serves them from the site itself. Any other image stays a link.
# Only plain PNG, JPEG or GIF files are taken, checked by their first bytes, not the name.
# Each must be at most IMAGE_MAX_BYTES (2 MB). No network is used.
# A bad image stays a link and is logged. It never stops the run.

# Print the images a proposal shows, one per line: each ![alt](address "title") after the
# front matter, found the same way as ccs-front-bash's markdown.awk.
image_addresses() {
    awk 'FNR == 1 { fm = ($0 ~ /^---[ \t\r]*$/); next }
        fm { if ($0 ~ /^(---|\.\.\.)[ \t\r]*$/) fm = 0; next }
        { s = $0
          while (match(s, /!\[[^]]*\]\([^) ]+( [^)]*)?\)/)) {
              m = substr(s, RSTART, RLENGTH); u = substr(m, index(m, "](") + 2); sub(/\)$/, "", u); sub(/ .*/, "", u)
              print u; s = substr(s, RSTART + RLENGTH)
          } }' "$1"
}

# image_type FILE: print png, jpg or gif from the first bytes. Fail for anything else.
image_type() {
    local m=''
    LC_ALL=C read -r -N 8 m < "$1" || true
    case $m in
        $'\x89PNG\r\n\x1a\n') echo png ;;
        $'\xff\xd8\xff'*) echo jpg ;;
        GIF87a* | GIF89a*) echo gif ;;
        *) return 1 ;;
    esac
}

# Copy the images the proposals show into OUTPUT_DIR/images/, drop the ones none shows any more,
# and write images.json.
proposal_images() {
    local dir=$OUTPUT_DIR/images map=$OUTPUT_DIR/images.json f stem a src dst root
    local -A keep=()
    IMAGE_MAX_BYTES=${IMAGE_MAX_BYTES:-2097152}
    mkdir -p "$dir" || return 1
    root=$(readlink -f "$PROPOSALS_DIR") || return 1
    while IFS= read -r f; do
        stem=${f%.md}
        [[ $stem =~ ^[A-Za-z0-9._-]+$ ]] || continue   # only proposals with plain names get images
        while IFS= read -r a; do
            [[ $a =~ ^images/$stem/[A-Za-z0-9._-]+\.(png|jpg|jpeg|gif)$ ]] || continue
            [[ -z ${keep[$a]:-} ]] || continue
            src=$PROPOSALS_DIR/$a
            # Check every step of the path, not only the last. A folder committed as a symlink
            # (images/p -> /etc/...) would otherwise bring in a file from outside.
            if [[ ! -f $src || -L $src || $(readlink -f "$src") != "$root/$a" ]]; then log "warning: $f shows $a, which isn't in the repository"; continue; fi
            if (($(wc -c < "$src") > IMAGE_MAX_BYTES)); then log "warning: $a is over $IMAGE_MAX_BYTES bytes, left a link"; continue; fi
            if ! image_type "$src" > /dev/null; then log "warning: $a is not a PNG, JPEG or GIF, left a link"; continue; fi
            dst=$dir/${a#images/}
            # Copy only when changed, keeping the file time, so the push sends it once.
            # Not cp -p: it also tries to keep the owner, which this account may not be allowed to.
            if ! diff -q "$src" "$dst" > /dev/null 2>&1; then
                if ! mkdir -p "${dst%/*}" || ! cp "$src" "$dst" || ! touch -r "$src" "$dst" || ! chmod 644 "$dst"; then
                    log "warning: could not copy $a"; continue
                fi
            fi
            keep[$a]=${a#images/}
        done < <(image_addresses "$PROPOSALS_DIR/$f")
    done < <(jq -r '.[].file' "$WORK/props.json")
    # Remove images no proposal shows any more. Empty folders stay; nothing lists them.
    # Also remove files directly in images/ (v0.2.10 kept fetched uploads there).
    for f in "$dir"/*; do if [[ -f $f ]]; then rm -f -- "$f"; fi; done
    for f in "$dir"/*/*; do
        [[ -e $f ]] || continue
        printf '%s\n' "${keep[@]}" | grep -qxF -- "${f#"$dir"/}" || rm -f -- "$f"
    done
    atomic_write "$map" images_json
}
images_json() {
    local a
    for a in "${!keep[@]}"; do printf '%s\t%s\n' "$a" "${keep[$a]}"; done \
        | jq -R -s 'split("\n") | map(select(. != "") | split("\t") | {(.[0]): .[1]}) | add // {}'
}

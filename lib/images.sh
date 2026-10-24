# shellcheck shell=bash
# A proposal's images: files in the proposals repository, inside an images folder, in a folder
# named after the proposal: images/<proposal>/<file> (my-proposal.md: images/my-proposal/chart.png),
# each shown in its .md as ![...](images/<proposal>/<file>), as the proposals CI requires of a
# merge request. The ones a proposal on the site shows are copied from the checkout into
# OUTPUT_DIR/images/ and listed in OUTPUT_DIR/images.json, {"images/<proposal>/<file>":
# "<proposal>/<file>"}, for ccs-front-bash to show from the site itself; any other image stays a
# link. Only plain files, PNG, JPEG or GIF (told by their first bytes, not the name),
# IMAGE_MAX_BYTES each (2 MB). No network. A bad image stays a link and is logged; it never stops
# the run.

# The images a proposal shows, one address a line: ![alt](address "title"), as ccs-front-bash's
# markdown.awk finds them, in the text after the front matter.
image_addresses() {
    awk 'FNR == 1 { fm = ($0 ~ /^---[ \t\r]*$/); next }
        fm { if ($0 ~ /^(---|\.\.\.)[ \t\r]*$/) fm = 0; next }
        { s = $0
          while (match(s, /!\[[^]]*\]\([^) ]+( [^)]*)?\)/)) {
              m = substr(s, RSTART, RLENGTH); u = substr(m, index(m, "](") + 2); sub(/\)$/, "", u); sub(/ .*/, "", u)
              print u; s = substr(s, RSTART + RLENGTH)
          } }' "$1"
}

# image_type FILE: png, jpg or gif from its first bytes; false for anything else
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
    local dir=$OUTPUT_DIR/images map=$OUTPUT_DIR/images.json f stem a src dst
    local -A keep=()
    IMAGE_MAX_BYTES=${IMAGE_MAX_BYTES:-2097152}
    mkdir -p "$dir" || return 1
    while IFS= read -r f; do
        stem=${f%.md}
        [[ $stem =~ ^[A-Za-z0-9._-]+$ ]] || continue   # images need a plain proposal name
        while IFS= read -r a; do
            [[ $a =~ ^images/$stem/[A-Za-z0-9._-]+\.(png|jpg|jpeg|gif)$ ]] || continue
            [[ -z ${keep[$a]:-} ]] || continue
            src=$PROPOSALS_DIR/$a
            if [[ ! -f $src || -L $src ]]; then log "warning: $f shows $a, which isn't in the repository"; continue; fi
            if (($(wc -c < "$src") > IMAGE_MAX_BYTES)); then log "warning: $a is over $IMAGE_MAX_BYTES bytes, left a link"; continue; fi
            if ! image_type "$src" > /dev/null; then log "warning: $a is not a PNG, JPEG or GIF, left a link"; continue; fi
            dst=$dir/${a#images/}
            # copied with its time, and only when it changed: the push sends it once
            if ! diff -q "$src" "$dst" > /dev/null 2>&1; then
                if ! mkdir -p "${dst%/*}" || ! cp -p "$src" "$dst" || ! chmod 644 "$dst"; then
                    log "warning: could not copy $a"; continue
                fi
            fi
            keep[$a]=${a#images/}
        done < <(image_addresses "$PROPOSALS_DIR/$f")
    done < <(jq -r '.[].file' "$WORK/props.json")
    # what no proposal shows any more goes (an emptied folder stays: harmless, nothing lists it),
    # and any file directly in images/ (v0.2.10 kept fetched uploads there)
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

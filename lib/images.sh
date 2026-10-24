# shellcheck shell=bash
# Images in proposals, kept on the site. An image uploaded to the proposals' own forge (a Forgejo
# attachment, a GitLab upload: what dragging a picture into a merge request makes) is fetched once
# into OUTPUT_DIR/images/, named by its upload ID, and listed in OUTPUT_DIR/images.json as
# {"<the address as the proposal writes it>": "<file>"}. ccs-front-bash shows those from the site
# itself and leaves every other image a link: a proposal page never loads anything from elsewhere.
# Only PNG, JPEG and GIF (told by their first bytes, not the name), IMAGE_MAX_BYTES each (2 MB),
# IMAGE_MAX_NEW new ones a run (20). Uploads never change, so one fetched is kept while a
# proposal shows it, and one refused (not an image, too big) is listed in images-refused.txt and
# not fetched again; a fetch that failed is tried again next run. A failure leaves that image a
# link; it never stops the run.

# The images a proposal shows, one address a line: ![alt](address "title"), as ccs-front-bash's
# markdown.awk finds them, in the text after the front matter.
image_addresses() {
    awk 'FNR == 1 { fm = ($0 ~ /^---[ \t\r]*$/); next }
        fm { if ($0 ~ /^(---|\.\.\.)[ \t\r]*$/) fm = 0; next }
        { s = $0
          while (match(s, /!\[[^]]*\]\([^) ]+( [^)]*)?\)/)) {
              m = substr(s, RSTART, RLENGTH); u = substr(m, index(m, "](") + 2); sub(/\)$/, "", u); sub(/ .*/, "", u)
              print u; s = substr(s, RSTART + RLENGTH)
          } }' "$@"
}

# image_upload ADDRESS: "<url to fetch>\t<upload ID>" if ADDRESS is an image uploaded to the
# forge REPOSITORY_URL names, as written there (relative or not); else nothing, and false.
image_upload() {
    local a=$1 base uuid='[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' name='[A-Za-z0-9._%+-]+'
    [[ ${REPOSITORY_URL:-} =~ ^(https://[^/]+)/ ]] || return 1
    base=${BASH_REMATCH[1]}
    if forgejo; then
        # /attachments/<uuid> or /<owner>/<repo>/attachments/<uuid>, on this host
        [[ $a == /* ]] && a=$base$a
        [[ $a =~ ^$base(/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+)?/attachments/($uuid)$ ]] || return 1
        printf '%s\t%s\n' "$a" "${BASH_REMATCH[2]}"
    else
        # /uploads/<32 hex>/<name>, relative to the project; or the whole address on this host
        if [[ $a =~ ^/uploads/([0-9a-f]{32})/($name)$ ]]; then
            [[ -n ${GITLAB_WEB_URL:-} ]] || GITLAB_WEB_URL=$(gitlab_project_url) || return 1
            [[ $GITLAB_WEB_URL =~ ^$base/[A-Za-z0-9._/-]+$ ]] || return 1
            a=$GITLAB_WEB_URL$a
        fi
        [[ $a =~ ^$base/[A-Za-z0-9._/-]+/uploads/([0-9a-f]{32})/$name$ ]] || return 1
        printf '%s\t%s\n' "$a" "${BASH_REMATCH[1]}"
    fi
}

# GitLab: the project's web address (https://host/group/project), for its relative /uploads/
gitlab_project_url() { curl -fsS --max-time 30 "$REPOSITORY_URL" | jq -r '.web_url // empty'; }

# image_get URL FILE: fetch URL into FILE (https only, redirects too; tests replace it)
image_get() {
    curl -fsS -L --proto '=https' --proto-redir '=https' --max-redirs 3 --max-time 30 \
        --max-filesize "$IMAGE_MAX_BYTES" -o "$2" "$1"
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

# Fetch the proposals' uploaded images that aren't here yet, drop the ones no proposal shows any
# more, and write images.json.
proposal_images() {
    local dir=$OUTPUT_DIR/images map=$OUTPUT_DIR/images.json refusedf=$OUTPUT_DIR/images-refused.txt files=() f a up url id file type size new=0
    local -A old=() keep=() refused=()
    IMAGE_MAX_BYTES=${IMAGE_MAX_BYTES:-2097152} IMAGE_MAX_NEW=${IMAGE_MAX_NEW:-20}
    mkdir -p "$dir" || return 1
    if [[ -s $map ]]; then
        while IFS=$'\t' read -r a file; do old[$a]=$file; done < <(jq -r 'to_entries[] | "\(.key)\t\(.value)"' "$map")
    fi
    if [[ -s $refusedf ]]; then while IFS= read -r id; do refused[$id]=1; done < "$refusedf"; fi
    while IFS= read -r f; do files+=("$PROPOSALS_DIR/$f"); done < <(jq -r '.[].file' "$WORK/props.json")
    while IFS= read -r a; do
        [[ -z ${keep[$a]:-} ]] || continue
        up=$(image_upload "$a") || continue
        IFS=$'\t' read -r url id <<<"$up"
        file=${old[$a]:-}
        if [[ -n $file && -s $dir/$file ]]; then keep[$a]=$file; continue; fi
        [[ -z ${refused[$id]:-} ]] || continue
        if ((new >= IMAGE_MAX_NEW)); then log "images: more than $IMAGE_MAX_NEW new, $id next run"; continue; fi
        new=$((new + 1))
        if ! image_get "$url" "$WORK/image" 2> /dev/null; then log "warning: could not fetch image $url"; continue; fi
        size=$(wc -c < "$WORK/image")
        if ((size > IMAGE_MAX_BYTES)); then
            log "warning: image $url is over $IMAGE_MAX_BYTES bytes, left a link"; refused[$id]=1; continue
        fi
        if ! type=$(image_type "$WORK/image"); then
            log "warning: $url is not a PNG, JPEG or GIF, left a link"; refused[$id]=1; continue
        fi
        file=$id.$type
        mv -f "$WORK/image" "$dir/$file" && chmod 644 "$dir/$file" || continue
        keep[$a]=$file
        log "image $file from $url"
    done < <(((${#files[@]})) && image_addresses "${files[@]}" | awk '!seen[$0]++')
    # what no proposal shows any more goes
    for f in "$dir"/*; do
        [[ -e $f ]] || continue
        file=${f##*/}
        printf '%s\n' "${keep[@]}" | grep -qxF -- "$file" || rm -f -- "$f"
    done
    if ((${#refused[@]})); then printf '%s\n' "${!refused[@]}" > "$refusedf.tmp" && mv -f "$refusedf.tmp" "$refusedf"; fi
    atomic_write "$map" images_json
}
images_json() {
    local a
    for a in "${!keep[@]}"; do printf '%s\t%s\n' "$a" "${keep[$a]}"; done \
        | jq -R -s 'split("\n") | map(select(. != "") | split("\t") | {(.[0]): .[1]}) | add // {}'
}

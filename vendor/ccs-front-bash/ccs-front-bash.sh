#!/usr/bin/env bash
# ccs-front-bash.sh ORIGINAL DATA PROPOSALS SITE SUBADDRESSES
# Fills the original (ccs-front-hugo's built site) with ccs-bash's JSON from DATA
# and the proposals' Markdown from PROPOSALS. The result goes in SITE.
# SUBADDRESSES is the signed list of the wallet's subaddresses.
# Every donation address must be on it, and its QR code is the list's own file.
# All HTML comes from the original's pages and parts. This only fills them in.
# The original is never changed. SITE is replaced only when the new one is complete.
# It needs no network and makes no QR codes.
# CCS_ONION: the site's onion address, for the footer. Without it, no onion line.
# CCS_SITE_URL: the site's address (https://host), for the feed and the link card's image.
# Without it, no feed, and the card's image keeps the design's path.
set -euo pipefail
export LC_ALL=C

LIB=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib
# shellcheck source=lib/fill.sh
source "$LIB/fill.sh"

# proposal_pages ORIGINAL DATA PROPOSALS OUT
# Makes a page for each proposal in fr, wip and cp, at its local-url. Ideas link to GitLab.
# One awk run renders all the Markdown and one jq run makes all the pages.
# Running them once per page would be slow.
proposal_pages() {
    local original=$1 data=$2 proposals=$3 out=$4 p=$1/parts file files=()
    mkdir -p "$out/proposals"
    while IFS= read -r file; do
        [[ -f $proposals/$file.md ]] || die "no proposal file $file.md"
        files+=("$proposals/$file.md")
    done < <(jq -r -L "$LIB" --slurpfile c "$data/completed-proposals.json" --slurpfile pr "$data/proposals.json" -n \
        'include "common"; paged($pr; $c) | .[1] | page_file')
    # The images ccs-bash copied from the repository.
    # Only plain names in images/<proposal>/<file> that exist are kept.
    # So no name can add markup or leave the folder.
    : > "$work/images.tsv"
    if [[ -f $data/images.json ]]; then
        jq -r 'to_entries[]
            | select((.key | test("^images/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+\\.(png|jpg|jpeg|gif)$")) and .key == "images/" + .value)
            | "\(.key)\t\(.value)"' "$data/images.json" | while IFS=$'\t' read -r a f; do
            if [[ $f != *..* && -f $data/images/$f ]]; then printf '%s\t%s\n' "$a" "$f"; fi
        done > "$work/images.tsv"
    fi
    cut -f2 "$work/images.tsv" | while IFS= read -r f; do
        # Keep its time, so the push sends it only when it changes.
        # Not cp -p, which also tries to keep the owner.
        mkdir -p "$out/images/${f%/*}" && cp "$data/images/$f" "$out/images/$f" && touch -r "$data/images/$f" "$out/images/$f"
    done
    printf '%s\0' "${files[@]}" | xargs -0 -r awk -v images="$work/images.tsv" -f "$LIB/markdown.awk" > "$work/md.jsonl"
    jq -nr -L "$LIB" --slurpfile proposals "$data/proposals.json" --slurpfile completed "$data/completed-proposals.json" \
        --slurpfile md "$work/md.jsonl" \
        --rawfile fr "$p/proposal-fr.html" --rawfile wip "$p/proposal-wip.html" --rawfile cp "$p/proposal-cp.html" \
        --rawfile donate "$p/donate.html" --rawfile funded "$p/funded.html" \
        --rawfile donatefunded "$([[ -f $p/donate-funded.html ]] && echo "$p/donate-funded.html" || echo /dev/null)" \
        --rawfile mdone "$p/milestone-done.html" --rawfile mtodo "$p/milestone-todo.html" \
        --rawfile payout "$p/payout.html" --rawfile nom "$p/no-milestones.html" --rawfile nop "$p/no-payouts.html" \
        --rawfile segdone "$p/segment-done.html" --rawfile segtodo "$p/segment-todo.html" \
        --rawfile labellink "$p/label-link.html" \
        --rawfile cidea "$work/regions/count_idea.html" --rawfile cfr "$work/regions/count_fr.html" \
        --rawfile cwip "$work/regions/count_wip.html" --rawfile ccp "$work/regions/count_cp.html" \
        --rawfile filters "$work/regions/filters.html" --arg verifylink "$verify_link" \
        --rawfile onion "$work/regions/onion.html" \
        --slurpfile qrs "$work/qr.json" -f "$LIB/pages.jq" > "$work/pages"
    # A line "\001<name>" starts the next page. pages.jq removes \001 from page text.
    awk -v dir="$out/proposals" '/^\001/ { if (f) close(f); f = dir "/" substr($0, 2) ".html"; next } { print > f }' "$work/pages"
}

# onion_region ORIGINAL
# The footer's line with the onion address from CCS_ONION.
# The gate must be given the same address, or it holds back every page.
# Empty without CCS_ONION, or if the original has no onion part.
onion_region() {
    local f
    : > "$work/regions/onion.html"
    [[ ${CCS_ONION:-} ]] || return 0
    [[ $CCS_ONION =~ ^[a-z2-7]{56}\.onion$ ]] || die "CCS_ONION is not an onion address (56 characters a-z and 2-7, then .onion)"
    [[ -f $1/parts/onion.html ]] || return 0
    f=$(cat "$1/parts/onion.html")
    printf '%s\n' "${f//\{\{onion\}\}/"$CCS_ONION"}" > "$work/regions/onion.html"
}

# feed DATA OUT
# Writes OUT/feed.xml: new ideas, proposals put to Funding Required, and fully funded ones.
# Its links need CCS_SITE_URL. Without it, there is no feed.
feed() {
    [[ ${CCS_SITE_URL:-} ]] || return 0
    local site
    site=$(site_url)
    jq -nr -L "$LIB" --arg site "$site" --slurpfile proposals "$1/proposals.json" \
        --slurpfile completed "$1/completed-proposals.json" -f "$LIB/feed.jq" > "$2/feed.xml"
}

# site_url: CCS_SITE_URL without its last /, checked to be https://host with no path.
site_url() {
    local site=${CCS_SITE_URL%/}
    [[ $site =~ ^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?$ ]] || die "CCS_SITE_URL is not a site's address (https://host, no path)"
    printf '%s\n' "$site"
}

# card_image SITE: the link-preview card's image (og:image) must be a full address.
# Put CCS_SITE_URL before the design's /assets/... path on every page.
# Without CCS_SITE_URL, the pages keep the path as it is.
card_image() {
    [[ ${CCS_SITE_URL:-} ]] || return 0
    local site
    site=$(site_url)
    find "$1" -name '*.html' -exec sed -i -E "s#(<meta property=\"og:image\" content=\")/([^/])#\\1$site/\\2#" {} +
}

# tag_regions ORIGINAL DATA
# Makes the tag filters and each tag page's regions in one jq run.
# Prints the tag slugs.
tag_regions() {
    local p=$1/parts data=$2 path
    jq -nr -L "$LIB" --slurpfile proposals "$data/proposals.json" --slurpfile completed "$data/completed-proposals.json" \
        --rawfile cardfr "$p/card-fr.html" --rawfile cardwip "$p/card-wip.html" --rawfile cardcp "$p/card-cp.html" \
        --rawfile segdone "$p/segment-done.html" --rawfile segtodo "$p/segment-todo.html" \
        --rawfile labelpart "$p/label.html" --rawfile filters "$p/filters.html" --rawfile filter "$p/filter.html" \
        -f "$LIB/tags.jq" > "$work/tags.out"
    mkdir -p "$work/tags"
    # Slugs are letters, digits and dashes, so they can't leave the folder.
    while IFS= read -r path; do
        [[ $path == filters || $path =~ ^[^/.]+/(list_fr|list_wip|list_cp|filters|title)$ ]] || die "bad tag region '$path'"
        if [[ $path == */title ]]; then
            mkdir -p "$work/tags/${path%/*}"
            printf '%s\n' "${path%/*}"
        fi
    done < <(awk '/^\001/ { print substr($0, 2) }' "$work/tags.out")
    awk -v tags="$work/tags" -v regions="$work/regions" '
        /^\001/ { if (f) close(f); n = substr($0, 2); f = (n == "filters") ? regions "/filters.html" : tags "/" n ".html"; next }
        { print > f }' "$work/tags.out"
}

# check_addresses ORIGINAL DATA LIST
# LIST is the signed list of the wallet's subaddresses, as "index address" lines.
# Beside it are LIST.asc, LIST.key.asc and LIST.pin (its sha256 and the key's fingerprint).
# LIST must match LIST.pin, and every donation address must be on it.
# The Verify page gets the fingerprint. Each donation box links to it.
# If the Verify part asks, it also gets the main address, the view key and the network.
# The view key is in LIST.viewkey. It may say where it was published:
# a "source <https link>" line, and a "source-text <words>" line for the link's text.
check_addresses() {
    local original=$1 data=$2 list=$3 sum fpr f main vk net src text
    verify_link=''   # global: the donation boxes' link to /verify/
    for f in "$list" "$list.asc" "$list.key.asc" "$list.pin"; do [[ -f $f ]] || die "no $f (see docs/setup.md, the signed list)"; done
    sum=$(sed -n 's/^sha256 *//p' "$list.pin") fpr=$(sed -n 's/^key *//p' "$list.pin")
    [[ $sum =~ ^[0-9a-f]{64}$ && $fpr =~ ^[0-9A-F]{40}$ ]] || die "$list.pin: want a 'sha256 <hex>' and a 'key <fingerprint>' line"
    [[ $(sha256sum < "$list" | cut -d' ' -f1) == "$sum" ]] || die "$list is not the list $list.pin pins"
    # A proposal whose address is not on the list is left off the site.
    # The rest is still made, so one bad file doesn't stop every page.
    # The run then exits 3, which counts as a failed run and alerts IRC.
    jq -r '.[1].proposals[] | ."donate-address" // empty' "$data/proposals.json" > "$work/addresses"
    awk 'NR == FNR { ok[$2] = 1; next } !($0 in ok)' "$list" "$work/addresses" > "$work/off"
    # The same for /projects: an address not on the list is taken out.
    : > "$work/offp"
    if [[ -f $data/projects.json ]]; then
        jq -r '.[] | .address // empty' "$data/projects.json" > "$work/paddresses"
        awk 'NR == FNR { ok[$2] = 1; next } !($0 in ok)' "$list" "$work/paddresses" > "$work/offp"
    fi
    if [[ -s $work/off || -s $work/offp ]]; then
        left_off=1   # global: main uses the data without them and exits 3
        jq -r --rawfile off "$work/off" '.[1].proposals[] | select(."donate-address" as $a | $off | split("\n") | any(.[]; . == $a))
            | "warning: left off the site: \(."local-url"): its donation address \(."donate-address"[0:6])… is not one of the wallet'"'"'s (the signed list)"' \
            "$data/proposals.json" | while IFS= read -r line; do log "$line"; done
        mkdir -p "$work/data"
        # Copy the rest as it is, images with their times. The image has no ln.
        for f in "$data"/*; do [[ ${f##*/} == proposals.json || ${f##*/} == projects.json ]] || cp -R "$f" "$work/data/"; done
        [[ ! -d $data/images ]] || (cd "$data/images" && find . -type f) | while IFS= read -r f; do
            touch -r "$data/images/$f" "$work/data/images/$f"
        done
        jq --rawfile off "$work/off" '.[1].proposals |= map(select(."donate-address" as $a | ($off | split("\n") | any(.[]; . == $a)) | not))' \
            "$data/proposals.json" > "$work/data/proposals.json"
        if [[ -f $data/projects.json ]]; then
            jq -r --rawfile off "$work/offp" '.[] | select(.address as $a | $off | split("\n") | any(.[]; . == $a))
                | "warning: /projects: \(.filename // .title | tostring | .[0:60]): address \(.address[0:6])… is not one of the wallet'"'"'s (the signed list): taken out"' \
                "$data/projects.json" | while IFS= read -r line; do log "$line"; done
            jq --rawfile off "$work/offp" 'map(if (.address as $a | $off | split("\n") | any(.[]; . == $a)) then .address = null else . end)' \
                "$data/projects.json" > "$work/data/projects.json"
        fi
    fi
    # Show the fingerprint as gpg does: 10 groups of 4, with two spaces in the middle.
    fpr=$(sed -E 's/(.{4})/\1 /g; s/ $//; s/^((.{4} ){5})/\1 /' <<<"$fpr")
    f=$(cat "$original/parts/verify.html")
    if [[ $f == *'{{address}}'* || $f == *'{{viewkey}}'* || $f == *'{{network}}'* || $f == *'{{wallet_source}}'* ]]; then
        main=$(awk '$1 == "0" { print $2; exit }' "$list")
        [[ $main =~ ^[0-9A-Za-z]{95}$ ]] || die "$list has no index 0 (the wallet's main address), which the Verify page shows"
        [[ -f $list.viewkey ]] || die "no $list.viewkey: the wallet's view key, which the Verify page shows (see docs/setup.md, the signed list)"
        vk=$(head -n 1 "$list.viewkey" | tr -d ' ')
        [[ $vk =~ ^[0-9a-f]{64}$ ]] || die "$list.viewkey: want the view key's 64 hex characters on its first line"
        src=$(sed -n 's/^source  *//p' "$list.viewkey")
        text=$(sed -n 's/^source-text  *//p' "$list.viewkey")
        [[ $text =~ ^[A-Za-z0-9\ .,:\'_-]*$ ]] || die "$list.viewkey: source-text: letters, digits, spaces and .,:'_- only"
        text=${text//\'/"&#39;"}   # quoted: in bash 5.2+ an unquoted & means the match
        if [[ -z $src ]]; then
            src='published by this site'
        elif [[ $src =~ ^https://[A-Za-z0-9._~:/?#@!$\&\'()*+,\;=%-]+$ && $src != *\"* ]]; then
            src="<a href=\"${src//&/"&amp;"}\">${text:-where they were published}</a>"
        else
            die "$list.viewkey: the source must be one https link"
        fi
        case $main in 9* | A*) net=' --testnet' ;; 5* | 7*) net=' --stagenet' ;; *) net='' ;; esac
        # Base58 and hex need no escaping.
        f=${f//\{\{address\}\}/"$main"} f=${f//\{\{viewkey\}\}/"$vk"} f=${f//\{\{network\}\}/"$net"}
        f=${f//\{\{wallet_source\}\}/"$src"}
    fi
    printf '%s\n' "${f//\{\{fingerprint\}\}/"$fpr"}" > "$work/regions/verify.html"
    verify_link=$(cat "$original/parts/verify-link.html")
}

# qr_codes DATA LIST
# Copies each donation address's QR code from LIST.qr/<address>.png.
# Its sum must match LIST.qr.sha256, which must match LIST.pin's qr line.
# The gate takes a QR code only as that exact file.
# Also writes qr.json, which maps each address to its image.
qr_codes() {
    local addr list=$2 sum
    mkdir -p "$work/qr"
    [[ -f $list.qr.sha256 && -d $list.qr ]] || die "no $list.qr.sha256 or $list.qr/: the list's QR codes (tools/make-qr.sh; docs/setup.md, the signed list)"
    sum=$(sed -n 's/^qr *//p' "$list.pin")
    [[ $sum =~ ^[0-9a-f]{64}$ ]] || die "$list.pin: no 'qr <sha256>' line (its QR codes' sums: tools/make-qr.sh, then sign-subaddresses.sh)"
    [[ $(sha256sum < "$list.qr.sha256" | cut -d' ' -f1) == "$sum" ]] || die "$list.qr.sha256 is not the one $list.pin pins"
    jq -r '[.[1].proposals[] | ."donate-address" // empty] | unique[]' "$1/proposals.json" | while IFS= read -r addr; do
        [[ $addr =~ ^[0-9A-Za-z]{95}$ ]] || die "not a donation address: '${addr:0:30}'"
        sum=$(awk -v f="$addr.png" '$2 == f { print $1; exit }' "$list.qr.sha256")
        [[ $sum && -f $list.qr/$addr.png && $(sha256sum < "$list.qr/$addr.png" | cut -d' ' -f1) == "$sum" ]] \
            || die "$list.qr/$addr.png is not its sum in $list.qr.sha256 (or missing)"
        cp "$list.qr/$addr.png" "$work/qr/$addr.png"
        printf '%s\n' "$addr"
    done | jq -R -s 'split("\n") | map(select(. != "") | {(.): "/qr/\(.).png"}) | add // {}' > "$work/qr.json"
}

# relative_links SITE
# Links from the data are absolute. Make each one relative to its page.
# Then a site served under /dark/ or /light/ stays there while browsing.
# One sed per folder depth. //host and https: links are left alone.
relative_links() {
    local depth prefix i
    for depth in 0 1 2 3 4 5; do
        prefix=./
        if ((depth)); then prefix=''; for ((i = 0; i < depth; i++)); do prefix+=../; done; fi
        find "$1" -mindepth $((depth + 1)) -maxdepth $((depth + 1)) -name '*.html' \
            -exec sed -i -E "s#((href|src)=\")/([^/])#\\1$prefix\\3#g" {} +
    done
}

main() {
    local original data proposals site subaddresses stage page tag tags f
    # Use absolute paths, then work from /.
    # Started from root's home, the current directory may not be readable.
    original=$(readlink -f "${1:?ORIGINAL}") data=$(readlink -f "${2:?DATA}")
    proposals=$(readlink -f "${3:?PROPOSALS}") site=$(readlink -f "${4:?SITE}")
    [[ ${5:-} ]] || die "no signed subaddress list (the fifth argument: docs/setup.md, the signed list)"
    subaddresses=$(readlink -f "$5")
    cd /
    [[ -f $original/index.html && -d $original/parts ]] || die "$original is not a built ccs-front-hugo site"
    [[ -f $original/explore/tag/example/index.html ]] || die "$original has no tag page (explore/tag/example/)"
    [[ -f $data/proposals.json && -f $data/completed-proposals.json ]] || die "no ccs-bash JSON in $data"
    [[ -d $proposals ]] || die "no proposals checkout at $proposals"
    work=$(mktemp -d)   # global: the EXIT trap needs it after main
    new=$site.new
    trap 'rm -rf "$work" "$new"' EXIT

    mkdir "$work/regions"
    onion_region "$original"
    # Check addresses first. A proposal left off is then off every list and count.
    check_addresses "$original" "$data" "$subaddresses"
    [[ -z ${left_off:-} ]] || data=$work/data
    # Make each list once. The same list goes on every page that shows it.
    for stage in idea fr wip cp; do
        jq -nr -L "$LIB" --arg stage "$stage" \
            --slurpfile proposals "$data/proposals.json" --slurpfile completed "$data/completed-proposals.json" \
            --rawfile card "$original/parts/card-$stage.html" --rawfile empty "$original/parts/empty.html" \
            --rawfile segdone "$original/parts/segment-done.html" --rawfile segtodo "$original/parts/segment-todo.html" \
            --rawfile labelpart "$original/parts/label.html" -f "$LIB/regions.jq" > "$work/regions/list_$stage.html"
    done
    # The number of proposals in each stage.
    # "count" is for the stage menu, "number" for the home page's cards.
    while read -r stage n; do
        printf '%s\n' "$n" > "$work/regions/count_$stage.html"
        printf '%s\n' "$n" > "$work/regions/number_$stage.html"
    done < <(jq -r --slurpfile c "$data/completed-proposals.json" \
        '"idea \(.[0].proposals | length)", "fr \(.[1].proposals | length)", "wip \(.[2].proposals | length)", "cp \($c[0][0].proposals | length)"' \
        "$data/proposals.json")

    qr_codes "$data" "$subaddresses"
    mapfile -t tags < <(tag_regions "$original" "$data")

    rm -rf "$new"
    mkdir "$new"
    (cd "$original" && tar -c --exclude=./parts --exclude=./proposals --exclude=./explore/tag --exclude=./qr .) | tar -x -C "$new"
    # The donation boxes' QR codes.
    cp -R "$work/qr" "$new/qr"
    while IFS= read -r -d '' page; do
        grep -q '<!-- ccs:' "$page" || continue
        fill_page "$page" "$work/regions" > "$page.tmp"
        mv "$page.tmp" "$page"
    done < <(find "$new" -name '*.html' -print0)
    # A page per tag, at the same depth as the original's, so its links still work.
    for tag in "${tags[@]}"; do
        cp "$work/regions"/count_*.html "$work/regions/onion.html" "$work/tags/$tag/"
        mkdir -p "$new/explore/tag/$tag"
        fill_page "$original/explore/tag/example/index.html" "$work/tags/$tag" > "$new/explore/tag/$tag/index.html"
    done
    proposal_pages "$original" "$data" "$proposals" "$new"
    # The /projects API goes with the site.
    if [[ -f $data/projects.json ]]; then cp "$data/projects.json" "$new/projects.json"; fi
    # site-data.json goes as it is. The web server checks it and builds the site from it.
    if [[ -f $data/site-data.json ]]; then cp "$data/site-data.json" "$new/site-data.json"; fi
    feed "$data" "$new"

    relative_links "$new"
    card_image "$new"

    rm -rf "$site.old"
    if [[ -e $site ]]; then mv "$site" "$site.old"; fi
    mv "$new" "$site"
    rm -rf "$site.old"
    log "filled $site (${#tags[@]} tag pages)"
    if [[ ${left_off:-} ]]; then log "error: an address not on the signed list was left off the site (see above)"; exit 3; fi
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi

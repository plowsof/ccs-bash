#!/usr/bin/env bash
# ccs-front-bash.sh ORIGINAL DATA PROPOSALS SITE SUBADDRESSES: fill the original (ccs-front-hugo's
# built site) with ccs-bash's JSON in DATA and the proposals' Markdown in PROPOSALS, into a new
# SITE. SUBADDRESSES: the signed list of the wallet's subaddresses (see check_addresses); every
# donation address must be in it, and its QR code is the list's own file, qr/<address>.png
# (qr_codes). Every piece of HTML comes from the original's pages and parts; this only fills
# them. The original is never changed; SITE is replaced only once the new one is complete. Needs
# no network, and makes no QR code. CCS_ONION: the site's onion address (NAME.onion), for
# the footer's onion line (onion_region); none, no line. CCS_SITE_URL: the site's address
# (https://host), for the feed's links (feed); none, no feed.
set -euo pipefail
export LC_ALL=C

LIB=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib
# shellcheck source=lib/fill.sh
source "$LIB/fill.sh"

# proposal_pages ORIGINAL DATA PROPOSALS OUT: a page per proposal in fr, wip and cp (ideas link
# to GitLab), at the local-url ccs-bash gave it. One awk run renders all the Markdown, one jq run
# makes all the pages: awk and jq once per page would take longer than the work.
proposal_pages() {
    local original=$1 data=$2 proposals=$3 out=$4 p=$1/parts file files=()
    mkdir -p "$out/proposals"
    while IFS= read -r file; do
        [[ -f $proposals/$file.md ]] || die "no proposal file $file.md"
        files+=("$proposals/$file.md")
    done < <(jq -r -L "$LIB" --slurpfile c "$data/completed-proposals.json" --slurpfile pr "$data/proposals.json" -n \
        'include "common"; paged($pr; $c) | .[1] | page_file')
    # the images ccs-bash copied from the repository (images.json, images/): only addresses
    # images/<proposal>/<file> and files <proposal>/<file>, plain names, that are there, so
    # nothing in them can make markup or leave the folder; copied into the site's images/
    : > "$work/images.tsv"
    if [[ -f $data/images.json ]]; then
        jq -r 'to_entries[]
            | select((.key | test("^images/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+\\.(png|jpg|jpeg|gif)$")) and .key == "images/" + .value)
            | "\(.key)\t\(.value)"' "$data/images.json" | while IFS=$'\t' read -r a f; do
            if [[ $f != *..* && -f $data/images/$f ]]; then printf '%s\t%s\n' "$a" "$f"; fi
        done > "$work/images.tsv"
    fi
    cut -f2 "$work/images.tsv" | while IFS= read -r f; do
        # with its time (the push then sends it only when it changed); not cp -p, which would also try
        # to keep the owner
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
    # split: a line "\001<name>" starts the next page (pages.jq removes \001 from page text)
    awk -v dir="$out/proposals" '/^\001/ { if (f) close(f); f = dir "/" substr($0, 2) ".html"; next } { print > f }' "$work/pages"
}

# onion_region ORIGINAL: the footer's line with the site's onion address (CCS_ONION, NAME.onion: the
# address the web server's gate is told too, or it holds every page back), in $work/regions; empty
# without one, or with an original that has no onion part (one from before it)
onion_region() {
    local f
    : > "$work/regions/onion.html"
    [[ ${CCS_ONION:-} ]] || return 0
    [[ $CCS_ONION =~ ^[a-z2-7]{56}\.onion$ ]] || die "CCS_ONION is not an onion address (56 characters a-z and 2-7, then .onion)"
    [[ -f $1/parts/onion.html ]] || return 0
    f=$(cat "$1/parts/onion.html")
    printf '%s\n' "${f//\{\{onion\}\}/"$CCS_ONION"}" > "$work/regions/onion.html"
}

# feed DATA OUT: OUT/feed.xml (lib/feed.jq), the proposals put to Funding Required and fully
# funded, for feed readers; its links need the site's address, CCS_SITE_URL: without it, none
feed() {
    [[ ${CCS_SITE_URL:-} ]] || return 0
    local site=${CCS_SITE_URL%/}
    [[ $site =~ ^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?$ ]] || die "CCS_SITE_URL is not a site's address (https://host, no path)"
    jq -nr -L "$LIB" --arg site "$site" --slurpfile proposals "$1/proposals.json" \
        --slurpfile completed "$1/completed-proposals.json" -f "$LIB/feed.jq" > "$2/feed.xml"
}

# tag_regions ORIGINAL DATA: the tag filters (into $work/regions) and each tag page's regions
# (into $work/tags/<slug>/), from one jq run; the tag slugs on stdout.
tag_regions() {
    local p=$1/parts data=$2 path
    jq -nr -L "$LIB" --slurpfile proposals "$data/proposals.json" --slurpfile completed "$data/completed-proposals.json" \
        --rawfile cardfr "$p/card-fr.html" --rawfile cardwip "$p/card-wip.html" --rawfile cardcp "$p/card-cp.html" \
        --rawfile segdone "$p/segment-done.html" --rawfile segtodo "$p/segment-todo.html" \
        --rawfile labelpart "$p/label.html" --rawfile filters "$p/filters.html" --rawfile filter "$p/filter.html" \
        -f "$LIB/tags.jq" > "$work/tags.out"
    mkdir -p "$work/tags"
    # tags.jq's slugs are letters, digits and dashes: no / or . to leave the folder with
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

# check_addresses ORIGINAL DATA LIST: with a signed list of the wallet's subaddresses (LIST,
# "index address" lines, tools/make-subaddresses.sh; beside it LIST.asc, LIST.key.asc and
# LIST.pin, its sha256 and the key's fingerprint, tools/sign-subaddresses.sh), LIST must be the
# one LIST.pin names and every donation address on the site must be in it; the Verify page gets
# the steps and the fingerprint, each donation box a link there, and the list, signature and key
# go out with the site. If the Verify part asks for them, it also gets the wallet's main address
# (the list's index 0), its view key (LIST.viewkey: public; a line "source <https link>" says
# where it was published, and "source-text <words>" what that link says) and the network, so a visitor can ask a copy of the wallet about an
# address.
check_addresses() {
    local original=$1 data=$2 list=$3 sum fpr f main vk net src text
    verify_link=''   # global, for pages.jq: the donation boxes' link to /verify/
    for f in "$list" "$list.asc" "$list.key.asc" "$list.pin"; do [[ -f $f ]] || die "no $f (see docs/setup.md, the signed list)"; done
    sum=$(sed -n 's/^sha256 *//p' "$list.pin") fpr=$(sed -n 's/^key *//p' "$list.pin")
    [[ $sum =~ ^[0-9a-f]{64}$ && $fpr =~ ^[0-9A-F]{40}$ ]] || die "$list.pin: want a 'sha256 <hex>' and a 'key <fingerprint>' line"
    [[ $(sha256sum < "$list" | cut -d' ' -f1) == "$sum" ]] || die "$list is not the list $list.pin pins"
    # a funding-required proposal whose address isn't the list's is left off the site (its page, its
    # card, the counts), the rest made: one stale file mustn't stop every page. The run then exits
    # 3, which the update script counts as a failed run (IRC hears of it).
    jq -r '.[1].proposals[] | ."donate-address" // empty' "$data/proposals.json" > "$work/addresses"
    awk 'NR == FNR { ok[$2] = 1; next } !($0 in ok)' "$list" "$work/addresses" > "$work/off"
    # /projects too (the site carries ccs-bash's projects.json): an address in it that isn't the
    # list's is taken out, the same failed run
    : > "$work/offp"
    if [[ -f $data/projects.json ]]; then
        jq -r '.[] | .address // empty' "$data/projects.json" > "$work/paddresses"
        awk 'NR == FNR { ok[$2] = 1; next } !($0 in ok)' "$list" "$work/paddresses" > "$work/offp"
    fi
    if [[ -s $work/off || -s $work/offp ]]; then
        left_off=1   # global: main uses the data without them, and exits 3
        jq -r --rawfile off "$work/off" '.[1].proposals[] | select(."donate-address" as $a | $off | split("\n") | any(.[]; . == $a))
            | "warning: left off the site: \(."local-url"): its donation address \(."donate-address"[0:6])… is not one of the wallet'"'"'s (the signed list)"' \
            "$data/proposals.json" | while IFS= read -r line; do log "$line"; done
        mkdir -p "$work/data"
        # the rest copied as it is (the image has no ln), images with their times (see proposal_pages)
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
    # the fingerprint as gpg shows it: 10 groups of 4, two spaces in the middle (hex: nothing to escape)
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
        text=${text//\'/"&#39;"}   # a quoted replacement: in bash 5.2+ an unquoted & means the match
        if [[ -z $src ]]; then
            src='published by this site'
        elif [[ $src =~ ^https://[A-Za-z0-9._~:/?#@!$\&\'()*+,\;=%-]+$ && $src != *\"* ]]; then
            src="<a href=\"${src//&/"&amp;"}\">${text:-where they were published}</a>"
        else
            die "$list.viewkey: the source must be one https link"
        fi
        case $main in 9* | A*) net=' --testnet' ;; 5* | 7*) net=' --stagenet' ;; *) net='' ;; esac
        # base58 and hex: nothing to escape
        f=${f//\{\{address\}\}/"$main"} f=${f//\{\{viewkey\}\}/"$vk"} f=${f//\{\{network\}\}/"$net"}
        f=${f//\{\{wallet_source\}\}/"$src"}
    fi
    printf '%s\n' "${f//\{\{fingerprint\}\}/"$fpr"}" > "$work/regions/verify.html"
    verify_link=$(cat "$original/parts/verify-link.html")
}

# qr_codes DATA LIST: $work/qr/<address>.png, a QR code (monero:<address>) for each donation
# address, and $work/qr.json, {"<address>": "/qr/<address>.png"}, the image each donation box
# shows (ccs-bash writes none, and one in its JSON would not be used): the list's own
# (LIST.qr/<address>.png, tools/make-qr.sh), its sum the one in LIST.qr.sha256, which must be
# the one LIST.pin's qr line names: the web server's gate takes a QR code only as that file, byte
# for byte.
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

# relative_links SITE: links from the data (a proposal's local-url, /proposals/x.html; a tag's
# page, /explore/tag/x/) are absolute. Make every one relative to its page, as the original's own
# links are, so a site served under a prefix keeps it while browsing: the theme is /dark/ or
# /light/ in the address. One sed per folder depth; //host and https: links are left alone.
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
    # absolute paths, then work from /: started by runuser from root's home, the current
    # directory may not be readable (find needs it)
    original=$(readlink -f "${1:?ORIGINAL}") data=$(readlink -f "${2:?DATA}")
    proposals=$(readlink -f "${3:?PROPOSALS}") site=$(readlink -f "${4:?SITE}")
    [[ ${5:-} ]] || die "no signed subaddress list (the fifth argument: docs/setup.md, the signed list)"
    subaddresses=$(readlink -f "$5")
    cd /
    [[ -f $original/index.html && -d $original/parts ]] || die "$original is not a built ccs-front-hugo site"
    [[ -f $original/explore/tag/example/index.html ]] || die "$original has no tag page (explore/tag/example/)"
    [[ -f $data/proposals.json && -f $data/completed-proposals.json ]] || die "no ccs-bash JSON in $data"
    [[ -d $proposals ]] || die "no proposals checkout at $proposals"
    work=$(mktemp -d)   # global: the EXIT trap still needs them after main
    new=$site.new
    trap 'rm -rf "$work" "$new"' EXIT

    mkdir "$work/regions"
    onion_region "$original"
    # the addresses first: a proposal left off (check_addresses) is off every list and count too
    check_addresses "$original" "$data" "$subaddresses"
    [[ -z ${left_off:-} ]] || data=$work/data
    # each list once: the same list goes on every page that shows it
    for stage in idea fr wip cp; do
        jq -nr -L "$LIB" --arg stage "$stage" \
            --slurpfile proposals "$data/proposals.json" --slurpfile completed "$data/completed-proposals.json" \
            --rawfile card "$original/parts/card-$stage.html" --rawfile empty "$original/parts/empty.html" \
            --rawfile segdone "$original/parts/segment-done.html" --rawfile segtodo "$original/parts/segment-todo.html" \
            --rawfile labelpart "$original/parts/label.html" -f "$LIB/regions.jq" > "$work/regions/list_$stage.html"
    done
    # how many proposals each stage has: "count" in the stage menu (every page), "number" on the
    # home page's stage cards
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
    # the donation boxes' QR codes, beside the pages that show them (qr_codes)
    cp -R "$work/qr" "$new/qr"
    while IFS= read -r -d '' page; do
        grep -q '<!-- ccs:' "$page" || continue
        fill_page "$page" "$work/regions" > "$page.tmp"
        mv "$page.tmp" "$page"
    done < <(find "$new" -name '*.html' -print0)
    # a page per tag: the original's tag page, at the same depth (its relative links still work)
    for tag in "${tags[@]}"; do
        cp "$work/regions"/count_*.html "$work/regions/onion.html" "$work/tags/$tag/"
        mkdir -p "$new/explore/tag/$tag"
        fill_page "$original/explore/tag/example/index.html" "$work/tags/$tag" > "$new/explore/tag/$tag/index.html"
    done
    proposal_pages "$original" "$data" "$proposals" "$new"
    # the /projects API goes with the site, so one push carries everything public
    if [[ -f $data/projects.json ]]; then cp "$data/projects.json" "$new/projects.json"; fi
    # and site-data.json, ccs-bash's (what only the backend knows), as it is: the web server checks
    # it, and is to build the site from it itself
    if [[ -f $data/site-data.json ]]; then cp "$data/site-data.json" "$new/site-data.json"; fi
    feed "$data" "$new"

    relative_links "$new"

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

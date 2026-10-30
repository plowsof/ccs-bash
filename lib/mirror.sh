# shellcheck shell=bash
# A mirror (MIRROR_URL in ccs.conf): this CCS shown beside another that runs on the same wallet
# (ccs.getmonero.org's ccs-back), for a while, to compare. Its /projects ({"data": [{title,
# author, address, raised_amount, contributions, ...}]}, no file names) gives each proposal's
# address, matched by title and author: the mirror never hands out a subaddress of its own, so a
# donation made through it is credited where the other site credits it. The totals are this
# CCS's own: this wallet's deposits, and an earlier wallet's from its retired record (CCS1's:
# RETIRED_DIR, as after a switch of wallets); only a proposal in neither (an address of a wallet
# before those, or none) shows the feed's raised amount and contributions (HISTORIC, written
# each run). A funding-required
# proposal the feed has no address for yet isn't on the site (ccs-front-bash shows none without
# one): it comes once the other site has given it one.

# the key a proposal is matched by: its title and author, spaces at either end dropped; when the
# feed has more than one of those (a proposal of the same name each quarter), its date too, as the
# feed writes it ("February 14, 2017")
MIRROR_KEY='((.title // "" | tostring | gsub("^\\s+|\\s+$"; "")) + "\u001f" + (.author // "" | tostring | gsub("^\\s+|\\s+$"; "")))'

# mirror_load: MIRROR_URL's projects as WORK/mirror.json, {key: {address, atomic, count}} ({dup: N}
# for a key N of them share: none of those is matched)
mirror_load() {
    # (16 MB at most: ccs.getmonero.org's is about 100 KB, and jq reads it whole)
    curl -fsS --max-time 60 --max-filesize 16777216 "$MIRROR_URL" > "$WORK/mirror.raw" || { log "error: could not fetch MIRROR_URL ($MIRROR_URL), or over 16 MB"; return 1; }
    # (the raised amount in piconero from its decimal number: exact to a piconero below 9007 XMR,
    # the feed's own precision far coarser)
    jq -c "(.data // .) | if type == \"array\" then . else error(\"not a list of projects\") end
        | map({key: $MIRROR_KEY, date: (.date // \"\" | tostring), address: (.address // \"\"),
               atomic: ((.raised_amount // 0 | tonumber) * 1000000000000 | round | tostring), count: (.contributions // 0)})
        | (group_by(.key) | map({key: .[0].key, value: (if length == 1 then .[0] | del(.key, .date) else {dup: length} end)}) | from_entries) as \$one
        | (group_by(.key + \"\\u001f\" + .date) | map({key: (.[0].key + \"\\u001f\" + .[0].date), value: (if length == 1 then .[0] | del(.key, .date) else {dup: length} end)}) | from_entries) as \$dated
        | \$one + \$dated" \
        "$WORK/mirror.raw" > "$WORK/mirror.json" 2> "$WORK/mirror.err" \
        || { log "error: MIRROR_URL's answer isn't a list of projects: $(head -c 200 "$WORK/mirror.err")"; return 1; }
}

# mirror_assign: in place of assign_addresses. Each proposal the state has no address for gets
# the feed's, if it is this wallet's (wallet-rpc's get_address_index: its index); one whose feed
# address is another wallet's, or has none, gets the feed's totals as history. A proposal shown
# with one address here and another in the feed stops the run: never a donation to an address
# the other site credits elsewhere. Never the main address (index 0: payout change lands there,
# and it counts for no proposal), one past any signed list, or one another proposal here has.
mirror_assign() {
    local file key dated many m addr have res err idx other n hist=$WORK/historic.tsv
    : > "$hist"
    # the proposals a retired record already has: theirs, never the feed's on top
    local -A retired=()
    while IFS= read -r file; do retired[$file]=1; done < <(awk -F, 'FNR > 1 && $6 != "" { print $6 }' "${RETIRED_DIR:-/nonexistent}"/*.csv 2> /dev/null)
    while IFS=$'\t' read -r file key dated many; do
        if ((many > 1)); then
            # several here of that title and author (a series): only the feed's one of this date.
            # The one of that name alone would do while the feed has one, but the feed may not list
            # the newest yet: it would get an older one's address
            m=''
            [[ $dated ]] && m=$(jq -c --arg k "$key"$'\x1f'"$dated" '.[$k] // empty' "$WORK/mirror.json")
            [[ $m ]] || continue
        else
            m=$(jq -c --arg k "$key" '.[$k] // empty' "$WORK/mirror.json")
            [[ $m ]] || continue
            # several of that title and author in the feed: the one of this date, if just one
            if jq -e '.dup' <<<"$m" > /dev/null && [[ $dated ]]; then
                m=$(jq -c --arg k "$key"$'\x1f'"$dated" '.[$k] // {dup: 2}' "$WORK/mirror.json")
            fi
        fi
        if jq -e '.dup' <<<"$m" > /dev/null; then
            log "warning: MIRROR_URL has more than one proposal with the title and author of $file, and of its date: none of them matched"
            continue
        fi
        addr=$(jq -r .address <<<"$m")
        have=$(jq -r --arg f "$file" '.[$f].address // ""' "$WORK/state.json")
        : > "$WORK/rpc.err" # this proposal's answer only (none at all for one the feed has no address for)
        if [[ $addr =~ ^[0-9A-Za-z]{95}$ ]] && res=$(rpc get_address_index "$(jq -nc --arg a "$addr" '{address: $a}')" 2> "$WORK/rpc.err") \
            && [[ $(jq -r '.index.major' <<<"$res") == 0 ]]; then
            idx=$(jq -r '.index.minor' <<<"$res")
            [[ $idx =~ ^$NUM$ ]] || die "unexpected get_address_index result: $res"
            if [[ $have ]]; then
                [[ $have == "$addr" ]] || die "$file shows $have here, but MIRROR_URL gives it $addr: stopped, so as never to show an address the other site credits elsewhere"
                continue
            fi
            if ((idx == 0 || idx > 100000)); then
                log "error: MIRROR_URL gives $file the wallet's subaddress $idx ($( ((idx)) && echo "past any signed list" || echo "its main address, which counts for no proposal")): not used"
                continue
            fi
            other=$(jq -r --argjson i "$idx" --arg f "$file" '[to_entries[] | select(.key != $f and .value.subaddr_index == $i) | .key][0] // ""' "$WORK/state.json")
            if [[ $other ]]; then
                log "error: MIRROR_URL gives $file subaddress $idx, which $other has here: not used"
                continue
            fi
            # created first: the wallet answers get_address_index for any subaddress it scans
            # for, but labels only those it has created (the other site's newest, often not yet)
            n=$(rpc get_address '{"account_index": 0}' | jq '.addresses | length') || return 1
            while ((n <= idx)); do
                rpc create_address '{"account_index": 0}' > /dev/null || return 1
                n=$((n + 1))
            done
            rpc label_address "$(jq -nc --argjson i "$idx" --arg l "$file" '{index: {major: 0, minor: $i}, label: $l}')" > /dev/null || return 1
            state_update --arg f "$file" --argjson i "$idx" --arg a "$addr" '.[$f] += {subaddr_index: $i, address: $a}'
            log "$file: subaddress $idx $addr (MIRROR_URL's)"
            continue
        fi
        # not this wallet's address: wallet-rpc says so (an earlier wallet's), or it has none.
        # Anything else (the wallet not answering) stops the run, not taken for history
        err=$(< "$WORK/rpc.err")
        if [[ $addr =~ ^[0-9A-Za-z]{95}$ && $err != *"belong"* ]]; then
            [[ $have ]] && continue
            log "error: the wallet couldn't say whose $file's address is: $err"; return 1
        fi
        [[ $have ]] && die "$file shows $have here, but MIRROR_URL's address for it isn't this wallet's: stopped"
        [[ ${retired[$file]:-} ]] || printf '%s\t%s\t%s\n' "$file" "$(jq -r .atomic <<<"$m")" "$(jq -r .count <<<"$m")" >> "$hist"
    done < <(jq -r "(map($MIRROR_KEY) | group_by(.) | map({key: .[0], value: length}) | from_entries) as \$here
        | .[] | [.file, $MIRROR_KEY, (if .ts > 0 then .ts | strftime(\"%B %-d, %Y\") else \"\" end), (\$here[$MIRROR_KEY] | tostring)] | @tsv" "$WORK/props.json")
    mv "$hist" "$HISTORIC"
}

# mirror_hide: a funding-required proposal with no address, not on the site until the feed has
# one (each run, the feed answering or not)
mirror_hide() {
    local skip file
    skip=$(jq -r --slurpfile s "$WORK/state.json" '.[] | select(.layout == "fr" and ($s[0][.file].address // null) == null) | .file' "$WORK/props.json")
    if [[ $skip ]]; then
        while IFS= read -r file; do echo "skipping $file: no address from MIRROR_URL yet" >&2; done <<<"$skip"
        jq --slurpfile s "$WORK/state.json" 'map(select(.layout != "fr" or ($s[0][.file].address // null) != null))' "$WORK/props.json" > "$WORK/props.tmp" \
            && mv "$WORK/props.tmp" "$WORK/props.json"
    fi
}

# historic_totals: "file<TAB>atomic<TAB>count" (HISTORIC, mirror_assign's), for proposal_funds
historic_totals() {
    [[ -n ${HISTORIC:-} && -f $HISTORIC ]] || return 0
    awk -F'\t' -v num='^[0-9]+$' 'NF == 3 && $2 ~ num && $3 ~ num' "$HISTORIC"
}

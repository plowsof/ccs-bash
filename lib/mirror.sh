# shellcheck shell=bash
# Mirror mode (MIRROR_URL in ccs.conf): run beside another CCS that uses the same wallet
# (ccs.getmonero.org's ccs-back), for a while, to compare the two.
# The other site's /projects feed gives each proposal's address: {"data": [{title, author,
# address, raised_amount, contributions, ...}]}. It has no file names, so proposals are
# matched by title and author.
# The mirror never hands out a subaddress of its own. A donation through it is credited
# where the other site credits it.
# Totals are counted here: this wallet's deposits, plus an earlier wallet's from its retired
# record (CCS1's, in RETIRED_DIR). Only a proposal found in neither shows the feed's raised
# amount and contribution count (written to HISTORIC each run).
# A Funding Required proposal with no address in the feed yet stays off the site, since
# ccs-front-bash can't show it without one. It appears once the other site gives it one.

# The key a proposal is matched by: title and author, trimmed, with HTML entities decoded
# (the feed writes "&" as "&amp;", the front matter as "&").
# When the feed has several with the same key (a proposal of the same name each quarter),
# the date is added, written as the feed writes it ("February 14, 2017").
MIRROR_TEXT='tostring | gsub("&lt;"; "<") | gsub("&gt;"; ">") | gsub("&quot;"; "\"") | gsub("&#39;|&#x27;|&apos;"; "\u0027") | gsub("&amp;"; "&") | gsub("^\\s+|\\s+$"; "")'
MIRROR_KEY="((.title // \"\" | $MIRROR_TEXT) + \"\\u001f\" + (.author // \"\" | $MIRROR_TEXT))"

# mirror_load: save MIRROR_URL's projects as WORK/mirror.json: {key: {address, atomic, count}}.
# A key shared by N proposals becomes {dup: N}. If the date doesn't separate them either, it is
# {dup: N, cands: [...]}, and mirror_assign picks one by the wallet's label.
mirror_load() {
    # 16 MB at most: ccs.getmonero.org's is about 100 KB, and jq reads it whole.
    curl -fsS --max-time 60 --max-filesize 16777216 "$MIRROR_URL" > "$WORK/mirror.raw" || { log "error: could not fetch MIRROR_URL ($MIRROR_URL), or over 16 MB"; return 1; }
    # Convert the raised amount to piconero. Exact below 9007 XMR, and the feed itself is far
    # less precise than that.
    jq -c "(.data // .) | if type == \"array\" then . else error(\"not a list of projects\") end
        | map({key: $MIRROR_KEY, date: (.date // \"\" | tostring), address: (.address // \"\"),
               atomic: ((.raised_amount // 0 | tonumber) * 1000000000000 | round | tostring), count: (.contributions // 0)})
        | (group_by(.key) | map({key: .[0].key, value: (if length == 1 then .[0] | del(.key, .date) else {dup: length} end)}) | from_entries) as \$one
        | (group_by(.key + \"\\u001f\" + .date) | map({key: (.[0].key + \"\\u001f\" + .[0].date), value: (if length == 1 then .[0] | del(.key, .date) else {dup: length, cands: map(del(.key, .date))} end)}) | from_entries) as \$dated
        | \$one + \$dated" \
        "$WORK/mirror.raw" > "$WORK/mirror.json" 2> "$WORK/mirror.err" \
        || { local why=''; IFS= read -r -N 200 why < "$WORK/mirror.err" || true   # first 200 characters: busybox's head has no -c
             log "error: MIRROR_URL's answer isn't a list of projects: $why"; return 1; }
}

# mirror_assign: used instead of assign_addresses in mirror mode.
# A proposal with no address in the state gets the feed's address, if it belongs to this wallet
# (wallet-rpc's get_address_index gives its index).
# If the feed's address belongs to another wallet, or there is none, the proposal gets the
# feed's totals as history instead.
# A proposal with one address here and a different one in the feed stops the run. We must never
# show an address the other site credits to a different proposal.
# Never used: the main address (index 0: payout change lands there and counts for no proposal),
# an index past any signed list, or an index another proposal here already has.
mirror_assign() {
    local file key dated many m addr have res err idx other n hist=$WORK/historic.tsv
    : > "$hist"
    # Proposals already in a retired record use that record, never the feed's totals on top.
    local -A retired=()
    while IFS= read -r file; do retired[$file]=1; done < <(awk -F, 'FNR > 1 && $6 != "" { print $6 }' "${RETIRED_DIR:-/nonexistent}"/*.csv 2> /dev/null)
    while IFS=$'\t' read -r file key dated many; do
        if ((many > 1)); then
            # Several proposals here share this title and author (a series). Match by date too.
            # Matching by name alone would work while the feed has only one, but the feed may not
            # list the newest yet, and it would get an older one's address.
            m=''
            [[ $dated ]] && m=$(jq -c --arg k "$key"$'\x1f'"$dated" '.[$k] // empty' "$WORK/mirror.json")
            [[ $m ]] || continue
        else
            m=$(jq -c --arg k "$key" '.[$k] // empty' "$WORK/mirror.json")
            [[ $m ]] || continue
            # Several in the feed share this title and author: take the one with this date, if unique.
            if jq -e '.dup' <<<"$m" > /dev/null && [[ $dated ]]; then
                m=$(jq -c --arg k "$key"$'\x1f'"$dated" '.[$k] // {dup: 2}' "$WORK/mirror.json")
            fi
        fi
        # Still several with the same date: take the one the wallet's label names.
        if jq -e '.cands' <<<"$m" > /dev/null; then m=$(mirror_pick "$file" "$m"); [[ $m ]] || m='{"dup": 2}'; fi
        if jq -e '.dup' <<<"$m" > /dev/null; then
            log "warning: MIRROR_URL has more than one proposal with the title and author of $file, and of its date, and the wallet's labels name none of them: none matched"
            continue
        fi
        addr=$(jq -r .address <<<"$m")
        have=$(jq -r --arg f "$file" '.[$f].address // ""' "$WORK/state.json")
        : > "$WORK/rpc.err" # this proposal's error only (none when the feed has no address for it)
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
            # Create it first. The wallet answers get_address_index for any subaddress it scans,
            # but can only label ones it has created (often not yet the other site's newest).
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
        # Not this wallet's address (wallet-rpc says so: an earlier wallet's), or no address.
        # Any other error, such as the wallet not answering, stops the run instead.
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

# mirror_pick FILE M: pick one of M's candidates (feed proposals with the same title, author and day).
# Prefer the one whose address FILE already has here. Otherwise the one whose subaddress the
# wallet labels FILE (labels from an earlier mirror, or the old ccs-back's file names).
# Prints it only if exactly one matches.
mirror_pick() {
    local have c a res idx label pick='' n=0
    have=$(jq -r --arg f "$1" '.[$f].address // ""' "$WORK/state.json")
    while IFS= read -r c; do
        a=$(jq -r .address <<<"$c")
        [[ $a =~ ^[0-9A-Za-z]{95}$ ]] || continue
        if [[ $have ]]; then
            [[ $a == "$have" ]] && { pick=$c; n=1; break; }
            continue
        fi
        res=$(rpc get_address_index "$(jq -nc --arg a "$a" '{address: $a}')" 2> /dev/null) || continue
        [[ $(jq -r '.index.major' <<<"$res") == 0 ]] || continue
        idx=$(jq -r '.index.minor' <<<"$res")
        [[ $idx =~ ^$NUM$ ]] || continue
        label=$(rpc get_address "{\"account_index\": 0, \"address_index\": [$idx]}" 2> /dev/null | jq -r '.addresses[0].label // ""') || continue
        [[ $label == "$1" ]] && { pick=$c; n=$((n + 1)); }
    done < <(jq -c '.cands[]' <<<"$2")
    ((n == 1)) && printf '%s\n' "$pick"
    return 0
}

# mirror_hide: keep Funding Required proposals with no address off the site until the feed
# gives them one. Runs every time, whether the feed answered or not.
mirror_hide() {
    local skip file
    skip=$(jq -r --slurpfile s "$WORK/state.json" '.[] | select(.layout == "fr" and ($s[0][.file].address // null) == null) | .file' "$WORK/props.json")
    if [[ $skip ]]; then
        while IFS= read -r file; do echo "skipping $file: no address from MIRROR_URL yet" >&2; done <<<"$skip"
        jq --slurpfile s "$WORK/state.json" 'map(select(.layout != "fr" or ($s[0][.file].address // null) != null))' "$WORK/props.json" > "$WORK/props.tmp" \
            && mv "$WORK/props.tmp" "$WORK/props.json"
    fi
}

# historic_totals: print HISTORIC's "file<TAB>atomic<TAB>count" lines (written by mirror_assign).
# Used by proposal_funds.
historic_totals() {
    [[ -n ${HISTORIC:-} && -f $HISTORIC ]] || return 0
    awk -F'\t' -v num='^[0-9]+$' 'NF == 3 && $2 ~ num && $3 ~ num' "$HISTORIC"
}

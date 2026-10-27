# shellcheck shell=bash
# GitLab API (public, no token): open MRs are "Ideas", merged MRs give each proposal its
# gitlab-url. Failures return non-zero explicitly: callers use `||`, where set -e is off.
#
# Or Forgejo / Gitea (git.disroot.org, codeberg.org...), told apart by REPOSITORY_URL:
# .../api/v4/projects/<id> is GitLab, .../api/v1/repos/<owner>/<repo> is Forgejo. Its pull
# requests are turned into GitLab's shape as they arrive (iid, web_url, author.username,
# created_at in UTC), so everything after this file is the same for both.

# gitlab_get PATH [CURL OPTION...]
gitlab_get() {
    curl -fsS --max-time 30 "${@:2}" "$REPOSITORY_URL/$1"
}

forgejo() { [[ ${REPOSITORY_URL:-} =~ /api/v1/repos/[^/]+/[^/]+/?$ ]]; }

# All MRs in state $1 (opened or merged), most recently updated first; with $2, no more pages once
# there are more than $2 (anyone can open MRs: the ideas look at IDEAS_MAX of them).
gitlab_mrs() {
    local page=1 batch all='[]'
    if forgejo; then
        forgejo_prs "$1" "${2:-}"
        return
    fi
    while :; do
        batch=$(gitlab_get "merge_requests?state=$1&scope=all&order_by=updated_at&per_page=100&page=$page") || return 1
        all=$(jq -s 'add' <<<"$all $batch") || return 1
        [[ $(jq length <<<"$batch") -eq 100 ]] || break
        [[ -z ${2:-} ]] || (($(jq length <<<"$all") <= $2)) || break
        page=$((page + 1))
    done
    printf '%s\n' "$all"
}

# Forgejo: pull requests open, or merged (closed and merged), as GitLab MRs. At most 50 a
# page (Forgejo's default limit); a full page means there may be another.
forgejo_prs() {
    local page=1 batch all='[]' state=open
    [[ $1 == opened ]] || state=closed
    while :; do
        batch=$(gitlab_get "pulls?state=$state&sort=recentupdate&limit=50&page=$page") || return 1
        all=$(jq -s --arg want "$1" '.[0] + (.[1] | map(select($want == "opened" or .merged == true) | {
            iid: .number, web_url: .html_url, title, author: {username: .user.login}, sha: .head.sha,
            # 2026-10-16T15:20:32+02:00 -> 2026-10-16T13:20:32Z (jq reads only Z times)
            created_at: (.created_at | if . == null then null else capture("^(?<t>[0-9-]{10}T[0-9:]{8})(\\.[0-9]+)?(?<z>Z|(?<s>[+-])(?<h>[0-9]{2}):(?<m>[0-9]{2}))$")
                | (.t + "Z" | fromdate) - (if .z == "Z" then 0 else (.s + "1" | tonumber) * ((.h | tonumber) * 3600 + (.m | tonumber) * 60) end)
                | todate end)
        }))' <<<"$all $batch") || return 1
        [[ $(jq length <<<"$batch") -eq 50 ]] || break
        [[ -z ${2:-} ]] || (($(jq length <<<"$all") <= $2)) || break
        page=$((page + 1))
    done
    printf '%s\n' "$all"
}

# Print the proposal file MR $1 adds: exactly one new .md in the repo root, and besides it only
# its images, inside an images folder: images/<its name>/<file>.png|jpg|jpeg|gif. Else nothing.
mr_proposal_file() {
    local files md f
    if forgejo; then
        files=$(gitlab_get "pulls/$1/files?limit=50" | jq -r '.[] | select(.status == "added") | .filename') || return 1
    else
        files=$(gitlab_get "merge_requests/$1/changes" | jq -r '.changes[] | select(.new_file) | .new_path') || return 1
    fi
    md=$(grep -E '\.md$' <<<"$files" || true)
    if [[ -z $md || $md == *$'\n'* ]] || ! safe_filename "$md"; then return 0; fi
    while IFS= read -r f; do
        [[ -z $f || $f == "$md" || $f =~ ^images/${md%.md}/[A-Za-z0-9._-]+\.(png|jpg|jpeg|gif)$ ]] || return 0
    done <<<"$files"
    printf '%s\n' "$md"
}

# Print the URL of the merged MR that added file $1, or nothing. The merged MRs fetched once per
# run; what each adds kept in MR_CACHE ("iid<TAB>file", STATE_DIR/merged-files.cache when ccs-back.sh
# sets it: a merged MR doesn't change), so a lookup cut short goes on from there next run. One MR
# that can't be read is passed over (the others still found): 1 at the end if the file wasn't.
merged_mr_url() {
    local iid url file failed='' cache=${MR_CACHE:-$WORK/merged-files.tsv}
    if [[ ! -s $WORK/merged.json ]]; then
        gitlab_mrs merged > "$WORK/merged.tmp" || return 1
        mv "$WORK/merged.tmp" "$WORK/merged.json"
    fi
    [[ -f $cache ]] || : > "$cache"
    while IFS=$'\t' read -r iid url; do
        [[ $iid =~ ^[0-9]+$ ]] || continue
        if ! file=$(awk -F'\t' -v i="$iid" '$1 == i { print $2; found = 1 } END { exit !found }' "$cache"); then
            file=$(mr_proposal_file "$iid") || { failed=1; continue; }
            printf '%s\t%s\n' "$iid" "$file" >> "$cache"
        fi
        if [[ $file == "$1" ]]; then
            printf '%s\n' "$url"
            return 0
        fi
    done < <(jq -r '.[] | [.iid, .web_url] | @tsv' "$WORK/merged.json")
    [[ ! $failed ]]
}

# is_address S: S (base58, 95 or 106 characters) is a Monero address, by its checksum: base58 as
# Monero has it (blocks of 11 characters, 8 bytes; the last, of 7, 5 bytes), Keccak-256 by openssl
# (3.2 or later). The first byte must be a network's (mainnet, testnet, stagenet; integrated and
# sub). 2 if openssl can't (then nothing is known).
B58=123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz
is_address() {
    local s=$1 i j b n c hex='' raw='' sum
    [[ (${#s} == 95 || ${#s} == 106) && $s =~ ^[45789AB][1-9A-HJ-NP-Za-km-z]+$ ]] || return 1
    for ((i = 0; i < ${#s}; i += 11)); do
        b=${s:i:11} n=0
        for ((j = 0; j < ${#b}; j++)); do c=${B58%%"${b:j:1}"*}; n=$((n * 58 + ${#c})); done
        # (an 11-character block can be over 2^64, wrapping: such an address's checksum fails anyway)
        if ((${#b} == 11)); then printf -v b '%016x' "$n"; else printf -v b '%010x' "$n"; fi
        hex+=$b
        ((i)) || [[ ${hex:0:2} =~ ^(12|13|18|19|24|2a|35|36|3f)$ ]] || return 1
    done
    for ((i = 0; i < ${#hex} - 8; i += 2)); do raw+="\\x${hex:i:2}"; done
    sum=$(printf '%b' "$raw" | openssl dgst -keccak-256 -r 2> /dev/null) || return 2
    [[ ${sum:0:8} == "${hex: -8}" ]]
}

# Forgejo: the 👍 and 👎 reactions on pull request $1 as {"upvotes": n, "downvotes": n}
# (GitLab has both on each MR already). 50 a page.
forgejo_votes() {
    local page=1 batch all='[]'
    while :; do
        batch=$(gitlab_get "issues/$1/reactions?limit=50&page=$page") || return 1
        all=$(jq -s '.[0] + (.[1] // [])' <<<"$all $batch") || return 1
        [[ $(jq 'length' <<<"$batch") -eq 50 ]] || break   # Forgejo sends null for none
        page=$((page + 1))
    done
    jq -c '{upvotes: map(select(.content == "+1")) | length, downvotes: map(select(.content == "-1")) | length}' <<<"$all"
}

# The proposal file $1 that an MR adds, at its commit $2, read as the site will read it once
# merged (frontmatter.awk): 0 if it reads; 1 if not, printing why; 2 if it can't be fetched.
# Anyone can open an MR, and its file lands on this disk: 1 MB at most (a proposal is a few KB).
# curl 8.4+ stops there even without a Content-Length (exit 63); an older one is caught after.
idea_file_reads() {
    local dir=$WORK/idea path line max=1048576 rc=0
    rm -rf "$dir" && mkdir -p "$dir" || return 2
    [[ -n $2 && $2 != null ]] || return 2
    path=$(jq -rn --arg f "$1" '$f | @uri')
    if forgejo; then
        gitlab_get "raw/$path?ref=$2" --max-filesize "$max" > "$dir/$1" || rc=$?
    else
        gitlab_get "repository/files/$path/raw?ref=$2" --max-filesize "$max" > "$dir/$1" || rc=$?
    fi
    if ((rc == 63)) || (($(wc -c < "$dir/$1") > max)); then
        rm -f "$dir/$1"
        echo "the file is over $max bytes"
        return 1
    fi
    ((rc == 0)) || return 2
    line=$(awk -f "$CCS_LIB/frontmatter.awk" "$dir/$1" 2> "$dir/why") || true
    [[ -n $line ]] && return 0
    sed -n '1s/^skipping [^:]*: //p' "$dir/why"
    return 1
}

# Print the "Ideas" list for ccs-front: open MRs adding a proposal that is not merged yet, and
# whose file reads as a proposal, with their 👍/👎 counts (null if they couldn't be read: the
# idea still shows).
# Anyone can open MRs, as many as they like: only the IDEAS_MAX (100) most recently updated are
# looked at, and what an MR at a commit adds, and whether its file reads, is kept in IDEAS_CACHE
# ("iid<TAB>commit<TAB>file<TAB>0 reads|1 doesn't|- no proposal", when set: ccs-back.sh's main sets
# it), so each is fetched once, not every run. Unset (the tests): everything is fetched.
ideas() {
    local mrs iid file sha why rc keep=() votes='{}' v max=${IDEAS_MAX:-100} cached='' fresh='' hit
    [[ $max =~ ^[0-9]+$ ]] || max=100
    mrs=$(gitlab_mrs opened "$max") || return 1
    if (($(jq length <<<"$mrs") > max)); then
        log "warning: more than $max open MRs, only the $max most recently updated are looked at for ideas"
    fi
    [[ -n ${IDEAS_CACHE:-} && -f $IDEAS_CACHE ]] && cached=$(cat "$IDEAS_CACHE")
    while IFS=$'\t' read -r iid sha; do
        hit=''
        [[ $iid =~ ^[0-9]+$ && $sha =~ ^[0-9A-Za-z._-]{1,64}$ ]] && hit=$(awk -F '\t' -v i="$iid" -v c="$sha" '$1 == i && $2 == c { print; exit }' <<<"$cached")
        if [[ $hit ]]; then
            IFS=$'\t' read -r _ _ file rc <<<"$hit"
            fresh+=$hit$'\n'
            [[ $file == - ]] && file=''
        else
            # an unreadable MR is left out, not the whole list
            if ! file=$(mr_proposal_file "$iid"); then
                log "warning: could not read MR !$iid, leaving it out of the ideas this run"
                continue
            fi
            rc=-
            # already in the repository (merged): no idea, and not kept, so it is seen again if not
            [[ -n $file && -e $PROPOSALS_DIR/$file ]] && continue
            if [[ -n $file ]]; then
                # its file must read as a proposal, as the site would read it: not just any .md
                rc=0; why=$(idea_file_reads "$file" "$sha") || rc=$?
                if ((rc == 2)); then
                    log "warning: could not fetch $file of MR !$iid, leaving it out of the ideas this run"
                    continue
                elif ((rc)); then
                    log "not an idea: MR !$iid's $file doesn't read as a proposal: ${why:-no reason given}"
                fi
            fi
            [[ $sha =~ ^[0-9A-Za-z._-]{1,64}$ ]] && fresh+=$iid$'\t'$sha$'\t'${file:--}$'\t'$rc$'\n'
        fi
        [[ -n $file && $rc == 0 && ! -e $PROPOSALS_DIR/$file ]] || continue
        keep+=("$iid")
        if forgejo; then
            v=$(forgejo_votes "$iid") || { log "warning: could not read the reactions on PR #$iid"; v=null; }
            votes=$(jq -c --arg i "$iid" --argjson v "$v" '.[$i] = $v' <<<"$votes")
        fi
    done < <(jq -r --argjson max "$max" '.[:$max][] | [.iid, (.sha // "")] | @tsv' <<<"$mrs")
    # the open MRs looked at this run only: a closed one's line goes
    [[ -z ${IDEAS_CACHE:-} ]] || atomic_write "$IDEAS_CACHE" printf '%s' "${fresh:-$'\n'}" || true

    # Anyone can open one, so a title or name can't hold a whole address (the web server's gate
    # would hold back every page listing it, as it does with the same rules): a run of 90 or more
    # characters each base58 or not ASCII (an address padded or split by invisible characters, or
    # drawn with look-alikes: a mathematical 9, a fullwidth or Cyrillic A; any character that isn't
    # ASCII, not only letters: jq's Unicode tables miss some) is shortened, as alerts show
    # addresses, to its first 6 and last 4. So is one split into groups by spaces or one of
    # . _ : - ("4A9b xZq3 ...") when, read joined, it holds an address (its checksum: is_address);
    # without openssl's Keccak, every such run (a long title of plain words too). Bidi controls go
    # first (they could show an address's halves, a space between them, in another order than
    # written), and control characters become spaces.
    local prep='def prep: gsub("[\u202a-\u202e\u2066-\u2069]"; "") | gsub("[\\x00-\\x1F\\x7F]"; " ")
            | gsub("(?<r>(?:[1-9A-HJ-NP-Za-km-z]|[^\\x00-\\x7F]){90,})"; .r | gsub("[^\\x20-\\x7E]"; "") | "\(.[0:6])…\(.[-4:])");
        def groups: "(?:[1-9A-HJ-NP-Za-km-z]|[^\\x00-\\x7F])(?:(?: +|[._:-])?(?:[1-9A-HJ-NP-Za-km-z]|[^\\x00-\\x7F])){89,}";'
    local run joined w n shorten=() keccak=1
    printf '' | openssl dgst -keccak-256 > /dev/null 2>&1 || keccak=''
    while IFS= read -r run; do
        if [[ -z $keccak ]]; then shorten+=("$run"); continue; fi
        joined=$(LC_ALL=C sed 's/[ ._:-]//g; s/[^1-9A-HJ-NP-Za-km-z]//g' <<<"$run")
        for n in 95 106; do
            for ((w = 0; w + n <= ${#joined}; w++)); do
                if is_address "${joined:w:n}"; then shorten+=("$run"); break 2; fi
            done
        done
    done < <(jq -r "$prep"' .[] | (.title, .author.username) | strings | prep | [scan(groups)] | .[]' <<<"$mrs")
    [[ $keccak ]] || ((${#shorten[@]} == 0)) || log "warning: openssl has no Keccak-256 (3.2 or later): ${#shorten[@]} idea title(s) shortened that may hold no address"
    jq --argjson keep "$(printf '%s\n' "${keep[@]}" | jq -s .)" --argjson votes "$votes" \
        --argjson shorten "$(printf '%s\n' "${shorten[@]}" | jq -R . | jq -s 'map(select(. != ""))')" "$prep"'
        def noaddress: prep | gsub("(?<r>" + groups + ")"; if .r | IN($shorten[]) then .r | gsub("[^\\x20-\\x7E]"; "") | "\(.[0:6])…\(.[-4:])" else .r end);
        map(select(.iid | IN($keep[])) | ($votes[.iid | tostring] // {upvotes, downvotes}) as $v | {
            name: (.title | sub("^\\s+"; "") | sub("\\s+$"; "") | noaddress | @html),
            "gitlab-url": (.web_url | if type == "string" and test("^https://[^\\s\"\\x27<>\\\\]+$") then @html else null end),
            author: (.author.username | noaddress | @html),
            date: (.created_at | sub("\\.[0-9]+"; "") | fromdate | strftime("%B %-d, %Y")),
            ts: (.created_at | sub("\\.[0-9]+"; "") | fromdate),
            upvotes: ($v.upvotes // null | if type == "number" then . else null end),
            downvotes: ($v.downvotes // null | if type == "number" then . else null end)
        }) | sort_by(-.ts) | map(del(.ts))' <<<"$mrs"
}

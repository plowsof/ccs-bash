# shellcheck shell=bash
# Filling the original: <!-- ccs:name -->…<!-- /ccs:name --> regions in a page, {{slots}} in a part.

log() { local m=$*; printf '%s %s\n' "$(date -u '+%F %T')" "${m//[[:cntrl:]]/?}" >&2; }
die() { log "error: $*"; exit 1; }

# fill_page PAGE REGIONS: print PAGE with every region's content replaced by the file
# REGIONS/<name>.html (spaces in the name as _). One pass, left to right: what is put in is
# never searched for markers again. A region with no file, no end marker, a marker inside it,
# or a name used twice in the page stops the run.
fill_page() {
    local page=$1 regions=$2 rest out='' name end frag seen=' '
    rest=$(cat "$page"; printf x)
    rest=${rest%x}
    while [[ $rest == *'<!-- ccs:'* ]]; do
        out+=${rest%%'<!-- ccs:'*}
        rest=${rest#*'<!-- ccs:'}
        name=${rest%%' -->'*}
        [[ $name =~ ^[a-z]+( [a-z]+)?$ ]] || die "$page: bad marker '<!-- ccs:${name:0:30}'"
        [[ $seen != *" $name|"* ]] || die "$page: marker '$name' used twice"
        seen+="$name| "
        rest=${rest#*' -->'}
        end="<!-- /ccs:$name -->"
        [[ $rest == *"$end"* ]] || die "$page: no $end"
        [[ ${rest%%"$end"*} != *'<!-- '*'ccs:'* ]] || die "$page: a marker inside '$name'"
        frag=$regions/${name// /_}.html
        [[ -f $frag ]] || die "$page: nothing to fill '$name' with"
        out+="<!-- ccs:$name -->"$'\n'"$(cat "$frag")"$'\n'"$end"
        rest=${rest#*"$end"}
    done
    [[ $rest != *'<!-- /ccs:'* ]] || die "$page: an end marker without its start"
    printf '%s' "$out$rest"
}

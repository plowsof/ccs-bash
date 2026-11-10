# shellcheck shell=bash
# Fills the original's regions (<!-- ccs:name -->…<!-- /ccs:name -->) and slots ({{name}}).

log() { local m=$*; printf '%s %s\n' "$(date -u '+%F %T')" "${m//[[:cntrl:]]/?}" >&2; }
die() { log "error: $*"; exit 1; }

# fill_page PAGE REGIONS
# Prints PAGE with each region replaced by REGIONS/<name>.html (spaces in the name as _).
# One pass, left to right, so inserted text is never searched again.
# The run stops on a region with no file, no end marker, a marker inside it, or a repeated name.
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

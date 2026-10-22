# Reads proposal .md files and prints one tab-separated line per valid file:
#   file  layout  title  author  date  amount  gitlab_url  milestones  done
# where date is "year month day" (or empty) and amount is a plain number.
# Invalid files are reported on stderr and skipped.
#
# This is not a YAML parser. It expects this shape and nothing fancier:
#
#   ---
#   layout: fr                      fr, wip or cp
#   title: Some title               or "double" / 'single' quoted, # comments allowed
#   author: someone
#   date: June 25th, 2021           words and numbers, month written out
#   amount: 1,500 XMR               leading number counts, commas are dropped
#   gitlab_url: https://...         optional
#   milestones:
#     - name: First milestone
#       done: 10 August 2021        any value at all means done
#   ---                             (or ...)
#
# Top-level keys start at column 0 and appear once. Other keys (payouts, ...) are ignored.
# Jekyll reads the same lines with a real YAML parser. Where the two could read a value
# differently (a value over several lines, block scalars, escapes, anchors, a line that is
# not "key: value") the file is skipped with the reason, instead of being read another way.
# A file starting with a BOM has no frontmatter for Jekyll either (it is published as is).
# Runs on mawk and gawk, so POSIX awk only.

BEGIN {
    OFS = "\t"
    nreq = split("layout title author date amount", req, " ")
    months = "janfebmaraprmayjunjulaugsepoctnovdec"
}

# "June 25th, 2021" (or 2021-06-25) -> "2021 6 25". Day defaults to 1, "" if no year or month.
function ymd(s,    t, n, i, w, k, y, m, d) {
    if (s ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]?-[0-9][0-9]?$/) {
        split(s, t, "-")
        return (t[1] + 0) " " (t[2] + 0) " " (t[3] + 0)
    }
    gsub(/[,.]/, " ", s)
    n = split(tolower(s), t, " ")
    for (i = 1; i <= n; i++) {
        w = t[i]
        if (w ~ /^[0-9]+(st|nd|rd|th)$/) sub(/[a-z]+$/, "", w)
        if (w ~ /^[0-9]+$/) {
            if (length(w) == 4) y = w + 0; else d = w + 0
        } else if (length(w) >= 3 && (k = index(months, substr(w, 1, 3))) % 3 == 1) {
            m = (k + 2) / 3
        }
    }
    if (!y || !m) return ""
    return y " " m " " (d ? d : 1)
}

# Remember the first reason this file can't be read like YAML reads it.
function bad(why) { if (perr == "") perr = why }

# A one-line YAML value as YAML reads it: plain, "double" or 'single' quoted, with an
# optional # comment after it. Anything else is bad().
function scalar(s,    i, c, out, rest) {
    if (s ~ /^"/) {
        i = index(substr(s, 2), "\"")
        if (!i) { bad("a quoted value goes on over several lines"); return "" }
        out = substr(s, 2, i - 1)
        if (index(out, "\\")) { bad("a backslash in a \"quoted\" value (use 'single' quotes)"); return "" }
        rest = substr(s, i + 2)
    } else if (s ~ /^'/) {
        out = ""
        for (i = 2; ; i++) {
            c = substr(s, i, 1)
            if (c == "") { bad("a quoted value goes on over several lines"); return "" }
            if (c == "'") {
                if (substr(s, i + 1, 1) != "'") break
                i++   # '' is one '
            }
            out = out c
        }
        rest = substr(s, i + 1)
    } else {
        if (s ~ /^#/) return ""
        sub(/ +#.*$/, "", s)   # " #" starts a comment
        if (s ~ /^[][{}>|&*!%@`]/ || s ~ /^[-?:]( |$)/ || s ~ /: / || s ~ /:$/) {
            bad("a value YAML reads as more than plain text: " s)
            return ""
        }
        return s
    }
    if (rest !~ /^( +#.*)?$/) bad("text after a quoted value: " rest)
    return out
}

function finish(    i, err, amount, name) {
    if (file == "") return
    name = file
    sub(/.*\//, "", name)
    amount = v["amount"]
    sub(/[^0-9.,].*$/, "", amount)
    gsub(/,/, "", amount)

    if (state != 2) err = "no frontmatter between --- lines"
    if (!err && perr != "") err = perr
    if (!err && dup != "") err = "key " dup " appears twice"
    for (i = 1; !err && i <= nreq; i++)
        if (v[req[i]] == "") err = "missing " req[i]
    if (!err && v["layout"] !~ /^(fr|wip|cp)$/) err = "layout must be fr, wip or cp"
    if (!err && amount !~ /^[0-9]+(\.[0-9]+)?$/) err = "amount is not a number"
    if (!err && milestones == 0) err = "no milestones"

    # it ends up in a link on the site: only plain https links, never javascript: and the like
    if (!err && v["gitlab_url"] != "" && v["gitlab_url"] !~ /^https:\/\/[^ "'<>\\]+$/) {
        print "ignoring gitlab_url of " name ": not an https link" > "/dev/stderr"
        v["gitlab_url"] = ""
    }
    if (err) print "skipping " name ": " err > "/dev/stderr"
    else print name, v["layout"], v["title"], v["author"], ymd(v["date"]), amount, v["gitlab_url"], milestones, done
    file = ""
}

# state: 0 = before frontmatter, 1 = inside, 2 = after, 3 = no frontmatter
FNR == 1 {
    finish()
    file = FILENAME
    state = 0; key = ""; milestones = 0; done = 0; dup = ""; perr = ""
    split("", v)
}
state >= 2 { next }
{ sub(/\r$/, ""); sub(/[ \t]+$/, ""); gsub(/\t/, " ") }
state == 0 { state = ($0 == "---") ? 1 : 3; next }
# Jekyll's YAML also ends the frontmatter at "...": stop there too, so nothing after it is
# read by ccs-bash but not by Jekyll (e.g. a second title, taking another proposal's place).
$0 == "---" || $0 == "..." { state = 2; next }

/^[A-Za-z0-9_-]+:( |$)/ {
    key = substr($0, 1, index($0, ":") - 1)
    val = substr($0, index($0, ":") + 1)
    sub(/^ +/, "", val)
    if (key ~ /^(layout|title|author|date|amount|gitlab_url)$/) val = scalar(val)
    # a key given twice is refused, not "last one wins" (YAML readers disagree on it)
    if (key in v && dup == "") dup = key
    v[key] = val
    next
}
/^ *$/ || /^ *#/ { next }
key == "milestones" && /^ *-/ { milestones++ }
key == "milestones" && /^ *(- )?done: *[^ ]/ { done++ }
# the value of a key we read, continued on the next line: YAML joins the lines
/^ / && key ~ /^(layout|title|author|date|amount|gitlab_url)$/ { bad("the value of " key " goes on over several lines") }
# list items at column 0 belong to the key above; anything else isn't "key: value"
/^[^ -]/ || /^-[^ ]/ { bad("line not understood: " substr($0, 1, 40)) }

END { finish() }

# Reads proposal .md files and prints one tab-separated line per valid file:
#   file  layout  title  author  date  amount  gitlab_url  milestones  done
# where date is "year month day" (or empty) and amount is a plain number.
# Invalid files are reported on stderr and skipped.
#
# This is not a YAML parser. It expects this shape and nothing fancier:
#
#   ---
#   layout: fr                      fr, wip or cp
#   title: Some title               may be wrapped in "double quotes"
#   author: someone
#   date: June 25th, 2021           words and numbers, month written out
#   amount: 1,500 XMR               leading number counts, commas are dropped
#   gitlab_url: https://...         optional
#   milestones:
#     - name: First milestone
#       done: 10 August 2021        any value at all means done
#   ---
#
# Top-level keys start at column 0. Other keys (payouts, ...) are ignored.
# Runs on mawk and gawk, so POSIX awk only.

BEGIN {
    OFS = "\t"
    nreq = split("layout title author date amount", req, " ")
    months = "janfebmaraprmayjunjulaugsepoctnovdec"
}

# "June 25th, 2021" -> "2021 6 25". Day defaults to 1, "" if no year or month.
function ymd(s,    t, n, i, w, k, y, m, d) {
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

function finish(    i, err, amount, name) {
    if (file == "") return
    name = file
    sub(/.*\//, "", name)
    amount = v["amount"]
    sub(/[^0-9.,].*$/, "", amount)
    gsub(/,/, "", amount)

    if (state != 2) err = "no frontmatter between --- lines"
    for (i = 1; !err && i <= nreq; i++)
        if (v[req[i]] == "") err = "missing " req[i]
    if (!err && v["layout"] !~ /^(fr|wip|cp)$/) err = "layout must be fr, wip or cp"
    if (!err && amount !~ /^[0-9]+(\.[0-9]+)?$/) err = "amount is not a number"
    if (!err && milestones == 0) err = "no milestones"

    if (err) print "skipping " name ": " err > "/dev/stderr"
    else print name, v["layout"], v["title"], v["author"], ymd(v["date"]), amount + 0, v["gitlab_url"], milestones, done
    file = ""
}

# state: 0 = before frontmatter, 1 = inside, 2 = after, 3 = no frontmatter
FNR == 1 {
    finish()
    file = FILENAME
    state = 0; key = ""; milestones = 0; done = 0
    split("", v)
}
state >= 2 { next }
{ sub(/\r$/, ""); sub(/[ \t]+$/, ""); gsub(/\t/, " ") }
state == 0 { state = ($0 == "---") ? 1 : 3; next }
$0 == "---" { state = 2; next }

/^[a-z_]+:/ {
    key = substr($0, 1, index($0, ":") - 1)
    val = substr($0, index($0, ":") + 1)
    sub(/^ +/, "", val)
    if (val ~ /^".*"$/) val = substr(val, 2, length(val) - 2)
    v[key] = val
    next
}
key == "milestones" && /^ +-/ { milestones++ }
key == "milestones" && /^ +(- )?done: *[^ ]/ { done++ }

END { finish() }

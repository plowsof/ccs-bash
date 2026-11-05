# awk -f markdown.awk A.md B.md ...: for each proposal, one JSON line:
#   {"file": "A", "body": "<h1>…", "milestones": [[name, funds, done], …], "payouts": [[date, amount], …]}
# body is the proposal's Markdown as HTML; milestones and payouts come from its front matter, as
# written (done empty: not done). One run for every proposal: starting awk and jq once per page
# would take longer than the work.
#
# Safe by construction: all text is HTML-escaped first, and the only tags in the output are the
# ones written here. Raw HTML in a proposal shows as text; links must be https:, #anchor or
# site-relative; images show as links (no requests to other sites), except a proposal's own images
# ccs-bash copied (-v images=FILE: "images/<proposal>/<file><TAB><proposal>/<file>" lines): those
# show, from the site's own images/. A strict subset: headings,
# paragraphs, lists (nested by indentation), code, quotes, tables, rules, emphasis, links.
# Anything else stays plain text. POSIX awk only (mawk, gawk, busybox).

BEGIN {
    # the images the site has a copy of: plain addresses and file names only (ccs-front-bash.sh checks)
    if (images != "") while ((getline l < images) > 0) { split(l, kv, "\t"); if (kv[2] != "") copy[kv[1]] = kv[2] }
}

FNR == 1 {
    if (started) finish()
    started = 1
    name = FILENAME; sub(/.*\//, "", name); sub(/\.md$/, "", name)
    fm = 0; n = 0; nph = 0; key = ""; item = 0; ms = ""; ps = ""
    split("", lines); split("", refs); split("", skip); split("", ph); split("", f)
    sub(/^\357\273\277/, "")
    if ($0 ~ /^---[ \t\r]*$/) { fm = 1; next }
}
END { if (started) finish() }

# ---- front matter: only the milestones and payouts lists are read here ----
fm == 1 {
    line = $0; sub(/\r$/, "", line)
    if (line ~ /^(---|\.\.\.)[ \t]*$/) { flushitem(); fm = 2; next }
    if (line ~ /^[A-Za-z0-9_-]+:/) { flushitem(); key = substr(line, 1, index(line, ":") - 1); next }
    if (key != "milestones" && key != "payouts") next
    if (line ~ /^ *- /) { flushitem(); sub(/^ *- /, "", line); item = 1 }
    if (!item) next
    sub(/^ +/, "", line)
    k = line; sub(/:.*/, "", k)
    v = line; if (index(v, ":")) { v = substr(v, index(v, ":") + 1) } else { v = "" }
    sub(/^ +/, "", v); sub(/ +$/, "", v)
    if (v ~ /^".*"$/ || v ~ /^'.*'$/) v = substr(v, 2, length(v) - 2)
    f[k] = v
    next
}
function flushitem() {
    if (!item) return
    if (key == "milestones") {
        if (ms != "") ms = ms ","
        ms = ms "[" json(f["name"]) "," json(f["funds"]) "," json(f["done"]) "]"
    } else {
        if (ps != "") ps = ps ","
        ps = ps "[" json(f["date"]) "," json(f["amount"]) "]"
    }
    item = 0; split("", f)
}

# ---- the body: kept, then rendered once the file is read (reference links can be anywhere) ----
# \001 and \002 mark held HTML below: a proposal can't bring its own.
{ sub(/\r$/, ""); gsub(/[\001\002]/, ""); lines[++n] = $0 }

function finish(    i, l, label, u) {
    for (i = 1; i <= n; i++)
        if (lines[i] ~ /^ ? ? ?\[[^]^][^]]*\]: *[^ ]+ *$/) {
            l = lines[i]; sub(/^ */, "", l)
            label = tolower(substr(l, 2, index(l, "]") - 2))
            u = substr(l, index(l, "]:") + 2); gsub(/ /, "", u)
            refs[label] = u; skip[i] = 1
        }
    html = ""
    render()
    print "{\"file\":" json(name) ",\"body\":" json(html) ",\"milestones\":[" ms "],\"payouts\":[" ps "]}"
}
function emit(s) { html = html s "\n" }

# JSON string: \ and " escaped, control characters as escapes or dropped
function repl(s, a, b,    out, k) {
    out = ""
    while ((k = index(s, a)) > 0) { out = out substr(s, 1, k - 1) b; s = substr(s, k + length(a)) }
    return out s
}
function json(s) {
    s = repl(s, "\\", "\\\\"); s = repl(s, "\"", "\\\""); s = repl(s, "\n", "\\n"); s = repl(s, "\t", "\\t")
    gsub(/[\001-\037\177]/, "", s)
    return "\"" s "\""
}

# ---------------------------------------------------------------- inline ------
function esc(s) {
    gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s)
    gsub(/"/, "\\&quot;", s); gsub(/'/, "\\&#39;", s)
    return s
}
# an entity written in the Markdown (&nbsp; &#8212;) is kept: it can't make a tag
function entities(s,    out) {
    out = ""
    while (match(s, /&amp;(#[0-9]+|#[xX][0-9a-fA-F]+|[A-Za-z][A-Za-z0-9]*);/)) {
        out = out substr(s, 1, RSTART - 1) "&" substr(s, RSTART + 5, RLENGTH - 5)
        s = substr(s, RSTART + RLENGTH)
    }
    return out s
}
# a placeholder for finished HTML, so later steps don't touch it
function hold(html) { ph[++nph] = html; return "\001" nph "\002" }
function unhold(s,    out, j) {
    while (match(s, /\001[0-9]+\002/)) {   # again until none: held HTML can hold more
        out = ""
        while (match(s, /\001[0-9]+\002/)) {
            j = substr(s, RSTART + 1, RLENGTH - 2) + 0
            out = out substr(s, 1, RSTART - 1) ph[j]
            s = substr(s, RSTART + RLENGTH)
        }
        s = out s
    }
    return s
}
# u is already escaped. A site-relative one starts "/" and a plain character: not "//", "/\" or
# an entity ("/&#47;"), which a browser reads as another site's address.
function safeurl(u) {
    return u ~ /^https:\/\/[^ \001\002]+$/ || u ~ /^#[A-Za-z0-9_-]+$/ || (u ~ /^\/[A-Za-z0-9._~-][^ \001\002]*$/ && u !~ /\\/)
}
function link(text, u, title) {
    if (!safeurl(u)) return text " (" u ")"
    return hold("<a href=\"" u "\">") text hold("</a>")
}
# **x**, *x*, ~~x~~: d the delimiter; "_" ones only between non-words, as Markdown does
function pairs(s, d, op, cl,    out, a, b, inner, pre, post) {
    out = ""
    while ((a = index(s, d)) > 0) {
        b = index(substr(s, a + length(d)), d)
        if (b == 0) break
        inner = substr(s, a + length(d), b - 1)
        pre = (a > 1) ? substr(s, a - 1, 1) : ""; post = substr(s, a + length(d) + b - 1 + length(d), 1)
        if (inner == "" || inner ~ /^ / || inner ~ / $/ || (d ~ /_/ && (pre ~ /[A-Za-z0-9]/ || post ~ /[A-Za-z0-9]/))) {
            out = out substr(s, 1, a + length(d) - 1); s = substr(s, a + length(d)); continue
        }
        out = out substr(s, 1, a - 1) op inner cl
        s = substr(s, a + length(d) + b - 1 + length(d))
    }
    return out s
}
function inline(s,    out, a, b, t, u, lab, m) {
    s = entities(esc(s))
    # escaped < > " ' are held, so they end a URL and never look like markup
    out = ""
    while (match(s, /&(lt|gt|quot|#39);/)) { out = out substr(s, 1, RSTART - 1) hold(substr(s, RSTART, RLENGTH)); s = substr(s, RSTART + RLENGTH) }
    s = out s
    # code spans first: nothing inside them is formatting
    out = ""
    while ((a = index(s, "`")) > 0 && (b = index(substr(s, a + 1), "`")) > 0) {
        out = out substr(s, 1, a - 1) hold("<code>" substr(s, a + 1, b - 1) "</code>")
        s = substr(s, a + b + 1)
    }
    s = out s
    # images become links: no requests to other sites from a proposal page; one the site has a
    # copy of shows, from there
    out = ""
    while (match(s, /!\[[^]]*\]\([^) ]+( [^)]*)?\)/)) {
        m = substr(s, RSTART, RLENGTH); t = substr(m, 3, index(m, "](") - 3); u = substr(m, index(m, "](") + 2); sub(/\)$/, "", u); sub(/ .*/, "", u)
        out = out substr(s, 1, RSTART - 1) ((u in copy) ? hold("<img src=\"/images/" copy[u] "\" alt=\"") t hold("\" loading=\"lazy\">") : link("image" (t == "" ? "" : ": " t), u))
        s = substr(s, RSTART + RLENGTH)
    }
    s = out s
    # [text](url), [text][label], [text][]
    out = ""
    while (match(s, /\[[^]]+\](\([^) ]+( [^)]*)?\)|\[[^]]*\])/)) {
        m = substr(s, RSTART, RLENGTH); t = substr(m, 2, index(m, "]") - 2); u = substr(m, index(m, "]") + 1)
        if (u ~ /^\(/) { u = substr(u, 2, length(u) - 2); sub(/ .*/, "", u) }   # a "title" after the URL is dropped
        else { lab = tolower(substr(u, 2, length(u) - 2)); if (lab == "") lab = tolower(t); u = (lab in refs) ? esc(refs[lab]) : "" }
        out = out substr(s, 1, RSTART - 1) (u == "" ? m : link(t, u))
        s = substr(s, RSTART + RLENGTH)
    }
    s = out s
    # bare https://… (a held < > " ' ends it)
    out = ""
    while (match(s, /https:\/\/[^ \001\002]+/)) {
        m = substr(s, RSTART, RLENGTH)
        t = ""; while (m ~ /[.,;:!?)]$/) { t = substr(m, length(m)) t; m = substr(m, 1, length(m) - 1) }
        out = out substr(s, 1, RSTART - 1) hold("<a href=\"" m "\">" m "</a>") t
        s = substr(s, RSTART + RLENGTH)
    }
    s = out s
    s = pairs(s, "**", "<strong>", "</strong>"); s = pairs(s, "__", "<strong>", "</strong>")
    s = pairs(s, "*", "<em>", "</em>"); s = pairs(s, "_", "<em>", "</em>")
    s = pairs(s, "~~", "<del>", "</del>")
    return unhold(s)
}

# ---------------------------------------------------------------- blocks ------
function flushpara(    i, t, br, po, pc) {
    if (np == 0) return
    t = ""
    for (i = 1; i <= np; i++) {
        br = (para[i - 1] ~ /  $/) ? "<br>\n" : "\n"
        if (i > 1) t = t br
        t = t inline(trim(para[i]))
    }
    po = (inquote || !nl) ? "<p>" : ""   # no <p> inside a tight list item
    pc = (inquote || !nl) ? "</p>" : ""
    emit(po t pc)
    np = 0
}
function trim(s) { sub(/^ +/, "", s); sub(/ +$/, "", s); return s }
function closelists(indent) {
    while (nl > 0 && lind[nl] >= indent) { flushpara(); emit("</li></" ltype[nl] ">"); nl-- }
}
function closeall() { flushpara(); closelists(0); if (inquote) { emit("</blockquote>"); inquote = 0 } if (intable) { emit("</tbody></table>"); intable = 0 } }
function cells(l, tag,    k, c, out, x) {
    l = trim(l); sub(/^\|/, "", l); sub(/\|$/, "", l)
    k = split(l, c, "|"); out = "<tr>"
    for (x = 1; x <= k; x++) out = out "<" tag ">" inline(trim(c[x])) "</" tag ">"
    return out "</tr>"
}
# a heading one level down (# is h2, ###### and below h6): the page's own h1 is the proposal's title
function heading(l,    lv, t, id, idattr) {
    lv = match(l, /^#+/) ? RLENGTH : 1
    t = substr(l, lv + 1); sub(/ #+ *$/, "", t); t = trim(t)
    id = tolower(t); gsub(/[^a-z0-9]+/, "-", id); sub(/^-/, "", id); sub(/-$/, "", id)
    idattr = (id == "") ? "" : " id=\"" id "\""
    lv = (lv < 6) ? lv + 1 : 6
    emit("<h" lv idattr ">" inline(t) "</h" lv ">")
}
function render(    i, l, ind, mark, t, typ, fence) {
    np = 0; nl = 0; inquote = 0; intable = 0; fence = ""
    for (i = 1; i <= n; i++) {
        if (skip[i]) continue
        l = lines[i]; gsub(/\t/, "    ", l)
        if (fence != "") {
            if (trim(l) ~ ("^" fence)) { emit("</code></pre>"); fence = "" } else emit(esc(l))
            continue
        }
        if (l ~ /^ *(```|~~~)/) { closeall(); fence = substr(trim(l), 1, 3); html = html "<pre><code>"; continue }
        if (l ~ /^ *$/) { flushpara(); if (inquote) { emit("</blockquote>"); inquote = 0 } if (intable) { emit("</tbody></table>"); intable = 0 } blank = 1; continue }
        if (intable && l ~ /\|/) { emit(cells(l, "td")); continue }
        if (l ~ /^ ? ? ?#+( |$)/ && match(trim(l), /^#+/) && RLENGTH <= 6) { closeall(); heading(trim(l)); continue }
        t = l; gsub(/ /, "", t)
        if (t ~ /^(---+|\*\*\*+|___+)$/ && np == 0) { closeall(); emit("<hr>"); continue }
        if (np == 1 && para[1] ~ /\|/ && t ~ /^\|?:?-+:?(\|:?-+:?)*\|?$/) {
            closelists(0); emit("<table><thead>" cells(para[1], "th") "</thead><tbody>"); np = 0; intable = 1; continue
        }
        if (l ~ /^ ? ? ?>/) {
            if (!inquote) { flushpara(); closelists(0); emit("<blockquote>"); inquote = 1 }
            sub(/^ *> ?/, "", l); para[++np] = l; continue
        }
        if (match(l, /^ *([-*+]|[0-9]+[.)]) +/)) {
            t = substr(l, RLENGTH + 1)
            ind = match(l, /[^ ]/) - 1
            mark = substr(l, ind + 1); typ = (mark ~ /^[0-9]/) ? "ol" : "ul"
            flushpara()
            closelists(ind + 1)
            if (nl > 0 && lind[nl] == ind && ltype[nl] != typ) closelists(ind)
            if (nl > 0 && lind[nl] == ind) { emit("</li>") }
            if (nl == 0 || lind[nl] < ind) { nl++; lind[nl] = ind; ltype[nl] = typ; emit("<" typ ">") }
            html = html "<li>"
            para[++np] = t; blank = 0
            continue
        }
        if (nl > 0 && blank && match(l, /[^ ]/) - 1 <= lind[nl]) closelists(0)
        if (nl > 0 && np == 0 && blank) { para[++np] = l; blank = 0; continue }
        para[++np] = l; blank = 0
    }
    if (fence != "") emit("</code></pre>")
    closeall()
}

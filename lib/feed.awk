# feed.awk (-v site=SITE) < FEED: ccs-receive's check of the feed (ccs-front-bash's feed.xml, RSS 2.0) line for line as it
# writes it; prints each linked page's name (decoded, one a line) once all of it passed, else the
# reason and exits 1. An
# item: "Funding required: " or "Fully funded: " and a title: escaped text, UTF-8, no markup even
# once a reader unescapes it (a reader may show a title as HTML: no &lt; or &gt;), no control or
# bidi characters, no run of 90 base58 or non-ASCII characters (an address, as ccs-check pages); a link and
# guid to the same proposal page of SITE, its name percent-encoded as jq @uri does; a date. At most
# 100 items. Plain POSIX awk, bytes (LC_ALL=C): gawk, mawk and busybox read it alike.
function fail(why) { print why; failed = 1; exit 1 }
# multibyte: each UTF-8 sequence as one \001; a byte left over 127 is not UTF-8
function chars(s) {
    gsub(/[\302-\337][\200-\277]|[\340-\357][\200-\277][\200-\277]|[\360-\364][\200-\277][\200-\277][\200-\277]/, "\001", s)
    return s
}
function title_ok(t,   u, w) {
    if (t == "" || t ~ /[\001-\037\177]/ || t ~ /\342\200[\252-\256]|\342\201[\246-\251]/) return 0
    u = t; gsub(/&(amp|quot|#39|apos);/, " ", u)
    if (u ~ /[<>"&]/) return 0
    w = chars(u)
    if (w ~ /[\200-\377]/ || length(w) > 1000) return 0
    while (match(w, /[1-9A-HJ-NP-Za-km-z\001]+/)) {
        if (RLENGTH >= 90) return 0
        w = substr(w, RSTART + RLENGTH)
    }
    return 1
}
# the file name a link names: %XX decoded (upper case, only where jq @uri encodes), else ""
function decode(e,   d, i, c, v) {
    if (e !~ /^[A-Za-z0-9._~%-]+$/ || length(e) > 1000) return ""
    d = ""
    for (i = 1; i <= length(e); i++) {
        c = substr(e, i, 1)
        if (c == "%") {
            if (substr(e, i + 1, 2) !~ /^[0-9A-F][0-9A-F]$/) return ""
            v = (index("0123456789ABCDEF", substr(e, i + 1, 1)) - 1) * 16 + index("0123456789ABCDEF", substr(e, i + 2, 1)) - 1
            c = sprintf("%c", v)
            if (v < 32 || v == 127 || v == 47 || c ~ /^[A-Za-z0-9._~-]$/) return ""
            i += 2
        }
        d = d c
    }
    if (d == "." || d == ".." || chars(d) ~ /[\200-\377]/) return ""
    return d
}
BEGIN {
    h[1] = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
    h[2] = "<rss version=\"2.0\" xmlns:atom=\"http://www.w3.org/2005/Atom\">"
    h[3] = "<channel>"
    h[4] = "<title>Monero Community Crowdfunding System</title>"
    h[5] = "<link>" site "/</link>"
    h[6] = "<description>Proposals put to Funding Required, and fully funded</description>"
    h[7] = "<atom:link href=\"" site "/feed.xml\" rel=\"self\" type=\"application/rss+xml\"/>"
    tag["Funding required"] = "funding-required"; tag["Fully funded"] = "funded"
    link = "<link>" site "/proposals/"; guid = "<guid isPermaLink=\"false\">" site "/proposals/"
    when = "^<pubDate>(Mon|Tue|Wed|Thu|Fri|Sat|Sun), [0-3][0-9] (Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) [0-9][0-9][0-9][0-9] [0-2][0-9]:[0-5][0-9]:[0-6][0-9] \\+0000</pubDate>$"
    k = 0; n = 0; done = 0
}
done { fail("not the feed (lines after its last)") }
length($0) > 5000 { fail("not the feed (a line of over 5000 bytes)") }
NR <= 7 { if ($0 != h[NR]) fail("not the feed (its first lines)"); next }
k == 0 && $0 == "</channel>" { k = -1; next }
k == -1 { if ($0 != "</rss>") fail("not the feed (its last lines)"); done = 1; next }
k == 0 { if ($0 != "<item>") fail("item " (n + 1) " is not one the feed has"); n++; if (n > 100) fail("over 100 items"); k = 1; next }
k == 1 {
    if (!match($0, /^<title>(Funding required|Fully funded): /) || substr($0, length($0) - 7) != "</title>") fail("item " n " is not one the feed has")
    kind = substr($0, 8, RLENGTH - 9)
    if (!title_ok(substr($0, RLENGTH + 1, length($0) - RLENGTH - 8))) fail("item " n " is not one the feed has")
    k = 2; next
}
k == 2 {
    if (substr($0, 1, length(link)) != link || substr($0, length($0) - 11) != ".html</link>") fail("item " n " is not one the feed has")
    enc = substr($0, length(link) + 1, length($0) - length(link) - 12)
    name = decode(enc)
    if (name == "") fail("item " n ": a link to no proposal page of this site")
    k = 3; next
}
k == 3 { if ($0 != guid enc ".html#" tag[kind] "</guid>") fail("item " n ": its link, guid and kind differ"); k = 4; next }
k == 4 { if ($0 !~ when) fail("item " n " is not one the feed has"); k = 5; next }
k == 5 { if ($0 != "</item>") fail("item " n " is not one the feed has"); names[n] = name; k = 0; next }
END {
    if (failed) exit 1
    if (!done) { print "not the feed (its last lines)"; exit 1 }
    for (i = 1; i <= n; i++) print names[i]
}

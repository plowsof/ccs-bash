# feed.xml, RSS 2.0 (feed in ccs-front-bash.sh): a proposal put to Funding Required, and one fully
# funded (ccs-bash's funding-required-at and funded-at, UTC), the 50 newest. $site: the site's
# address, https://host. Plain text only: a reader may show a title as HTML, so a title's &lt; and
# &gt; become ‹ and › (the web server's gate refuses them, ccs-receive feed_py). Its lines are
# exactly the ones the gate checks.
include "common";

def rfc822: fromdate | strftime("%a, %d %b %Y %H:%M:%S +0000");
def plain: escaped | gsub("&lt;"; "‹") | gsub("&gt;"; "›");
# a page's address in a link: its file name as it is (local-url is HTML-escaped), percent-encoded
# (a space, # or ? in a name would break the link); nothing in it then needs escaping in XML
def href: escaped | gsub("&quot;"; "\"") | gsub("&#39;|&apos;"; "'") | gsub("&lt;"; "<") | gsub("&gt;"; ">") | gsub("&amp;"; "&")
  | "/proposals/\(ltrimstr("/proposals/") | rtrimstr(".html") | @uri).html";

[($proposals[0], $completed[0])[] | .proposals[]
  | select((."local-url" // "") | test("^/proposals/[^/]+\\.html$"))
  | (select(."funding-required-at") | {at: ."funding-required-at", kind: "Funding required", tag: "funding-required"} + {p: .}),
    (select(."funded-at") | {at: ."funded-at", kind: "Fully funded", tag: "funded"} + {p: .})]
| sort_by(.at, .tag, .p."local-url") | reverse | .[:50]
| "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
  "<rss version=\"2.0\" xmlns:atom=\"http://www.w3.org/2005/Atom\">",
  "<channel>",
  "<title>Monero Community Crowdfunding System</title>",
  "<link>\($site)/</link>",
  "<description>Proposals put to Funding Required, and fully funded</description>",
  "<atom:link href=\"\($site)/feed.xml\" rel=\"self\" type=\"application/rss+xml\"/>",
  (.[] | (.p."local-url" | href) as $url
    | "<item>",
      "<title>\(.kind): \(.p.name | plain)</title>",
      "<link>\($site)\($url)</link>",
      "<guid isPermaLink=\"false\">\($site)\($url)#\(.tag)</guid>",
      "<pubDate>\(.at | rfc822)</pubDate>",
      "</item>"),
  "</channel>",
  "</rss>"

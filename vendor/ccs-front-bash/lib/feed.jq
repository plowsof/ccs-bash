# feed.xml, RSS 2.0 (feed in ccs-front-bash.sh). Items: a proposal put to Funding Required, one
# fully funded (ccs-bash's funding-required-at and funded-at, UTC), and a new idea (its MR's
# created-at, UTC; only the 10 newest, since anyone can open an MR). The 50 newest items in all.
# $site: the site's address, https://host. Plain text only: a reader may show a title as HTML, so
# a title's &lt; and &gt; become ‹ and › (the web server's gate refuses them). Its lines are
# exactly the ones the gate checks.
include "common";

def rfc822: fromdate | strftime("%a, %d %b %Y %H:%M:%S +0000");
def plain: escaped | gsub("&lt;"; "‹") | gsub("&gt;"; "›");
# a page's address in a link: its file name as it is (local-url is HTML-escaped), percent-encoded
# (a space, # or ? in a name would break the link); nothing in it then needs escaping in XML
def href: escaped | gsub("&quot;"; "\"") | gsub("&#39;|&apos;"; "'") | gsub("&lt;"; "<") | gsub("&gt;"; ">") | gsub("&amp;"; "&")
  | "/proposals/\(ltrimstr("/proposals/") | rtrimstr(".html") | @uri).html";

# A new idea links to its MR on the forge (ccs-bash checks it is one of the proposals repository's)
def ideas: [$proposals[0][] | select(.stage == "Ideas") | .proposals[]
  | select((."created-at" // "") | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
  | select((."gitlab-url" // "") | test("^https://[^\\s\"'<>]+$"))]
  | sort_by(."created-at") | reverse | .[:10]
  | map({at: ."created-at", kind: "New idea", tag: "idea", key: ."gitlab-url", link: (."gitlab-url" | escaped), name});

[($proposals[0], $completed[0])[] | .proposals[]
  | select((."local-url" // "") | test("^/proposals/[^/]+\\.html$"))
  | . as $p | {key: ."local-url", link: ($site + (."local-url" | href)), name} as $e
  | (select($p."funding-required-at") | $e + {at: $p."funding-required-at", kind: "Funding required", tag: "funding-required"}),
    (select($p."funded-at") | $e + {at: $p."funded-at", kind: "Fully funded", tag: "funded"})]
  + ideas
| sort_by(.at, .tag, .key) | reverse | .[:50]
| "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
  "<rss version=\"2.0\" xmlns:atom=\"http://www.w3.org/2005/Atom\">",
  "<channel>",
  "<title>Monero Community Crowdfunding System</title>",
  "<link>\($site)/</link>",
  "<description>Proposals put to Funding Required, fully funded, and new ideas</description>",
  "<atom:link href=\"\($site)/feed.xml\" rel=\"self\" type=\"application/rss+xml\"/>",
  (.[]
    | "<item>",
      "<title>\(.kind): \(.name | plain)</title>",
      "<link>\(.link)</link>",
      "<guid isPermaLink=\"false\">\(.link)#\(.tag)</guid>",
      "<pubDate>\(.at | rfc822)</pubDate>",
      "</item>"),
  "</channel>",
  "</rss>"

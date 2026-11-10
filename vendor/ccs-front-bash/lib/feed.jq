# feed.xml, in RSS 2.0.
# Items: proposals put to Funding Required, fully funded ones, and new ideas.
# Only the 10 newest ideas, since anyone can open an MR. 50 items in all.
# $site is the site's address, https://host.
# Plain text only. A reader may show a title as HTML, so &lt; and &gt; become ‹ and ›.
# Its lines are exactly the ones the gate checks.
include "common";

def rfc822: fromdate | strftime("%a, %d %b %Y %H:%M:%S +0000");
def plain: escaped | gsub("&lt;"; "‹") | gsub("&gt;"; "›");
# A page's link: its file name, unescaped, then percent-encoded.
# A space, # or ? in a name would break the link. The result needs no XML escaping.
def href: escaped | gsub("&quot;"; "\"") | gsub("&#39;|&apos;"; "'") | gsub("&lt;"; "<") | gsub("&gt;"; ">") | gsub("&amp;"; "&")
  | "/proposals/\(ltrimstr("/proposals/") | rtrimstr(".html") | @uri).html";

# A new idea links to its MR. ccs-bash checks the MR is in the proposals repository.
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

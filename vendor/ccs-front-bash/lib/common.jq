# Shared by regions.jq (the lists) and pages.jq (proposal pages).

# Amounts come exact to 4 decimals. Show them without trailing zeros.
def trim0: tostring | if test("\\.") then sub("0+$"; "") | sub("\\.$"; "") else . end;

# ccs-bash HTML-escapes every text it writes.
# Text that isn't escaped means something went wrong, so stop.
def escaped: if test("[<>\"']") then error("not HTML-escaped: \(.)") else . end;

# The values of a proposal's slots.
def values:
  {
    url: (."local-url" // ."gitlab-url" // "#"),
    gitlab_url: (."gitlab-url" // "#"),
    name: .name,
    author: .author,
    date: (.date // ""),
    contributors: (.contributions // 0),
    amount: ((.amount // "0") | trim0),
    raised: ((."amount-funded" // "0") | trim0),
    percentage: (.percentage // 0),
    milestones: (.milestones // 0),
    done: (."milestones-completed" // 0),
    address: (."donate-address" // ""),
    pending_note: (if (."amount-pending" // 0) > 0 then " +\(."amount-pending" | trim0) XMR pending" else "" end),
    # What is still needed, rounded up, counting pending donations.
    # Empty when nothing more is needed.
    needed_note: (if ((."amount-needed" // "0") | tonumber) > 0 then " \(."amount-needed" | trim0) XMR would fund it 100%!" else "" end),
    funding_note: (if ."funding-required-date" then " · funding since \(."funding-required-date")" else "" end),
    # When funding started, or else the front matter's date.
    funding_date: (."funding-required-date" // .date // ""),
    # An idea's 👍/👎. Null or missing if they couldn't be read.
    upvotes: (.upvotes | if type == "number" then . else "–" end),
    downvotes: (.downvotes | if type == "number" then . else "–" end)
  }
  | map_values(tostring | escaped);

# Fill a part's slots from $v in one pass. A slot with no value stops the run.
def fill($v): gsub("\\{\\{(?<k>[a-z_]+)\\}\\}"; $v[.k] // error("no value for {{\(.k)}}"));

# Undo ccs-bash's HTML escaping. For names in paths only, never for page text.
def unescape: gsub("&#39;"; "'") | gsub("&apos;"; "'") | gsub("&quot;"; "\"") | gsub("&gt;"; ">") | gsub("&lt;"; "<") | gsub("&amp;"; "&");

# A proposal's tags as [{tag, slug}]. The slug names the page /explore/tag/<slug>/.
# So "Abandoned" and "abandoned!" are one filter.
# Slugs are letters and digits with dashes between. A tag with neither gets no filter.
def slug: unescape | ascii_downcase | gsub("[^\\p{L}\\p{N}]+"; "-") | sub("^-+"; "") | sub("-+$"; "");
# A tag's colour, one of tag-0 to tag-7, from its slug.
# The same tag always gets the same colour.
def tag_color: "tag-\(reduce explode[] as $c (0; (. * 31 + $c) % 1000003) % 8)";
def tag_list:
  [(.tags // [])[] | select(type == "string") | escaped | {tag: ., slug: slug} | select(.slug != "")
   | . + {color: (.slug | tag_color)}]
  | reduce .[] as $t ([]; if any(.[]; .slug == $t.slug) then . else . + [$t] end);
def tag_href: "/explore/tag/\(.slug | @uri)/";
# A card's labels (plain, as the card is one link) and a proposal page's tag links.
def labels($part): [tag_list[] | . as $t | $part | rtrimstr("\n") | fill({tag: $t.tag, color: $t.color})] | join("");
def tag_links($part): [tag_list[] | . as $t | $part | rtrimstr("\n") | fill({tag: $t.tag, color: $t.color, href: ($t | tag_href)})] | join("");

# The milestone bar of a card: one segment part per milestone.
def segments($done; $todo):
  . as $v | [range(0; $v.milestones | tonumber) | if . < ($v.done | tonumber) then $done else $todo end]
  | map(rtrimstr("\n")) | join("");

# One card per proposal in $list, or the empty part. With $empty null, nothing.
def cards($list; $card; $empty; $segdone; $segtodo; $labelpart):
  if ($list | length) == 0 then ($empty // "") | rtrimstr("\n")
  else $list | map((values + {segments: (values | segments($segdone; $segtodo)), tags: labels($labelpart)}) as $v
    | $card | rtrimstr("\n") | fill($v)) | join("\n")
  end;

# A proposal's page file name, from its local-url, unescaped.
# It must be a plain name, with no folders and nothing hidden.
def page_file:
  ."local-url" | ltrimstr("/proposals/") | rtrimstr(".html") | unescape
  | if test("^[^/.][^/[:cntrl:]]*$") then . else error("bad page name: \(.)") end;

# The proposals that get a page, with their stage. Ideas link to GitLab.
def paged($proposals; $completed):
  ($proposals[0][1].proposals[] | ["fr", .]), ($proposals[0][2].proposals[] | ["wip", .]), ($completed[0][0].proposals[] | ["cp", .]);

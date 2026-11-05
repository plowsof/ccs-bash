# Shared by regions.jq (the lists) and pages.jq (proposal pages).

# Amounts are ccs-bash's (exact to 4 decimals, cut off), shown without trailing zeros.
def trim0: tostring | if test("\\.") then sub("0+$"; "") | sub("\\.$"; "") else . end;

# ccs-bash already HTML-escapes every text it writes (names, authors, links): one that is not
# escaped means something upstream went wrong, so stop rather than escape it twice or not at all.
def escaped: if test("[<>\"']") then error("not HTML-escaped: \(.)") else . end;

# A proposal from ccs-bash's JSON -> the values of its {{slots}}.
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
    # what would fund it, pending counted (ccs-bash's amount-needed, rounded up): beside the donate
    # box's first step; nothing when nothing more is needed, or from a ccs-bash before it
    needed_note: (if ((."amount-needed" // "0") | tonumber) > 0 then " \(."amount-needed" | trim0) XMR would fund it 100%!" else "" end),
    funding_note: (if ."funding-required-date" then " · funding since \(."funding-required-date")" else "" end),
    # a funding-required proposal's one date: when funding started, else (a state without it) the
    # date its front matter gives
    funding_date: (."funding-required-date" // .date // ""),
    # an idea's 👍/👎 (ccs-bash: null if they couldn't be read, missing before ccs-bash had them)
    upvotes: (.upvotes | if type == "number" then . else "–" end),
    downvotes: (.downvotes | if type == "number" then . else "–" end)
  }
  | map_values(tostring | escaped);

# Fill a part's {{slots}} from $v in one pass; a slot with no value stops the run.
def fill($v): gsub("\\{\\{(?<k>[a-z_]+)\\}\\}"; $v[.k] // error("no value for {{\(.k)}}"));

# Undo ccs-bash's HTML escaping (for file names and tag names in paths; never put in a page).
def unescape: gsub("&#39;"; "'") | gsub("&apos;"; "'") | gsub("&quot;"; "\"") | gsub("&gt;"; ">") | gsub("&lt;"; "<") | gsub("&amp;"; "&");

# A proposal's tags (ccs-bash's, escaped) -> [{tag, slug}]: the slug names the tag's page,
# /explore/tag/<slug>/, so "Abandoned" and "abandoned!" are one filter. Letters (any script)
# and digits, dashes between; a tag with none gets no filter. The first spelling is kept.
def slug: unescape | ascii_downcase | gsub("[^\\p{L}\\p{N}]+"; "-") | sub("^-+"; "") | sub("-+$"; "");
# A tag's colour, one of the original's 8 classes (tag-0 to tag-7), from its slug: the same tag
# has the same colour everywhere, every run, with nothing to configure.
def tag_color: "tag-\(reduce explode[] as $c (0; (. * 31 + $c) % 1000003) % 8)";
def tag_list:
  [(.tags // [])[] | select(type == "string") | escaped | {tag: ., slug: slug} | select(.slug != "")
   | . + {color: (.slug | tag_color)}]
  | reduce .[] as $t ([]; if any(.[]; .slug == $t.slug) then . else . + [$t] end);
def tag_href: "/explore/tag/\(.slug | @uri)/";
# a card's labels (the card is one link: plain labels) and a proposal page's tag links
def labels($part): [tag_list[] | . as $t | $part | rtrimstr("\n") | fill({tag: $t.tag, color: $t.color})] | join("");
def tag_links($part): [tag_list[] | . as $t | $part | rtrimstr("\n") | fill({tag: $t.tag, color: $t.color, href: ($t | tag_href)})] | join("");

# The milestone bar of a card: one segment part per milestone.
def segments($done; $todo):
  . as $v | [range(0; $v.milestones | tonumber) | if . < ($v.done | tonumber) then $done else $todo end]
  | map(rtrimstr("\n")) | join("");

# One card per proposal in $list, or the empty part ($empty null: nothing).
def cards($list; $card; $empty; $segdone; $segtodo; $labelpart):
  if ($list | length) == 0 then ($empty // "") | rtrimstr("\n")
  else $list | map((values + {segments: (values | segments($segdone; $segtodo)), tags: labels($labelpart)}) as $v
    | $card | rtrimstr("\n") | fill($v)) | join("\n")
  end;

# A proposal's page file name: its local-url without /proposals/ and .html, and without the
# HTML escaping ccs-bash gave it. Checked: a plain name, no folders, nothing hidden.
def page_file:
  ."local-url" | ltrimstr("/proposals/") | rtrimstr(".html") | unescape
  | if test("^[^/.][^/[:cntrl:]]*$") then . else error("bad page name: \(.)") end;

# The proposals that get a page (ideas link to GitLab), with their stage.
def paged($proposals; $completed):
  ($proposals[0][1].proposals[] | ["fr", .]), ($proposals[0][2].proposals[] | ["wip", .]), ($completed[0][0].proposals[] | ["cp", .]);

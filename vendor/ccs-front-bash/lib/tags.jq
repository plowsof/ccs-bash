# The tag filters and the tag pages' regions, in one run.
# Each file is printed after a line "\u0001<path>".
# "filters" is the sidebar on every page but a tag page.
# Each tag gets <slug>/list_fr, list_wip, list_cp, filters and title.
# With no tags, the filters are empty and there are no tag pages.
# --slurpfile proposals, completed: ccs-bash's JSON.
# --rawfile cardfr, cardwip, cardcp, segdone, segtodo, labelpart, filters, filter: the parts.
include "common";

def part: rtrimstr("\n");

{fr: $proposals[0][1].proposals, wip: $proposals[0][2].proposals, cp: $completed[0][0].proposals} as $lists
| # The card parts' links are relative to parts/, one folder down.
# Tag pages are three folders down, so fix the links.
# This changes only the part's markup, before any value is filled in.
{fr: $cardfr, wip: $cardwip, cp: $cardcp} | map_values(gsub("=\"\\.\\./"; "=\"../../../")) as $card
# Every tag, with its first spelling and its count, most used first.
| [$lists.fr[], $lists.wip[], $lists.cp[] | tag_list[]] as $all
| ($all | group_by(.slug) | map(.[0] + {count: length}) | sort_by(-.count, .slug)) as $tags
| def nav($active):
    if ($tags | length) == 0 then ""
    else (($tags | map({tag, color, href: tag_href, count: (.count | tostring),
                          active: (if .slug == $active then " active" else "" end)}))
          | map(. as $x | $filter | part | fill($x)) | join("")) as $f
      | $filters | part | fill({filters: $f})
    end;
  "\u0001filters\n\(nav(null))",
  ($tags[] | . as $t
   | ("fr", "wip", "cp") as $s
   | "\u0001\($t.slug)/list_\($s)\n" + cards([$lists[$s][] | select(any(tag_list[]; .slug == $t.slug))]; $card[$s]; null; $segdone; $segtodo; $labelpart)),
  ($tags[] | "\u0001\(.slug)/filters\n\(nav(.slug))", "\u0001\(.slug)/title\n\(.tag)")

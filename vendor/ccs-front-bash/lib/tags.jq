# The tag filters and the tag pages' regions, in one run. Prints each file after a line
# "\u0001<path>" (see ccs-front-bash.sh): "filters" (the sidebar's, every page but a tag page), and for each tag
# "<slug>/list_fr", "<slug>/list_wip", "<slug>/list_cp", "<slug>/filters", "<slug>/title".
# No tags at all: the filters are empty and there are no tag pages.
# Inputs: --slurpfile proposals, completed (ccs-bash's JSON); --rawfile cardfr, cardwip, cardcp,
# segdone, segtodo, labelpart, filters, filter (parts).
include "common";

def part: rtrimstr("\n");

{fr: $proposals[0][1].proposals, wip: $proposals[0][2].proposals, cp: $completed[0][0].proposals} as $lists
| # The card parts' own links (icons) are relative to parts/, one folder down like the stage pages; the
# tag pages are three down (explore/tag/<slug>/). Only the part's markup is changed, before
# any value is filled in.
{fr: $cardfr, wip: $cardwip, cp: $cardcp} | map_values(gsub("=\"\\.\\./"; "=\"../../../")) as $card
# every tag with its first spelling and how many proposals have it, most used first
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

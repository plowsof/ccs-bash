# Every proposal page, in one run.
# Each starts as parts/proposal-<stage>.html. Its slots are filled, then its regions.
# Each page is printed after a line "\u0001<file name>".
# --slurpfile proposals, completed: ccs-bash's JSON. md: markdown.awk's output. qrs: QR code paths.
# --rawfile fr, wip, cp, donate, funded, donatefunded, mdone, mtodo, payout, nom, nop,
#   segdone, segtodo, labellink: the parts.
# --rawfile cidea, cfr, cwip, ccp, filters: the sidebar's counts and tags.
include "common";

def part: rtrimstr("\n");

# Replace what is between <!-- ccs:NAME --> and <!-- /ccs:NAME -->. Each must be there once.
# It runs after the slots are filled. Inserted text is not looked at again.
def region($name; $html):
  ("<!-- ccs:\($name) -->") as $a | ("<!-- /ccs:\($name) -->") as $b
  | split($a) as $x
  | if ($x | length) != 2 then error("<!-- ccs:\($name) --> \($x | length - 1) times") else . end
  | ($x[1] | split($b)) as $y
  | if ($y | length) != 2 then error("<!-- /ccs:\($name) --> \($y | length - 1) times") else . end
  | $x[0] + $a + "\n" + $html + "\n" + $b + $y[1];

# The same, for a region some pages don't have, like payouts on a funding page.
# If the marker is missing, the page stays as it is.
def region_if_there($name; $html):
  if contains("<!-- ccs:\($name) -->") then region($name; $html) else . end;

($md | map({key: .file, value: .}) | from_entries) as $byfile
| {fr: $fr, wip: $wip, cp: $cp} as $tpl
| paged($proposals; $completed) | .[0] as $stage | .[1] as $p
| ($p | page_file) as $file
| ($byfile[$file] // error("no proposal file \($file).md")) as $m
# Milestones and payouts are the proposal's own text, so escape them here.
| ($m.milestones | map(map(@html) | {name: .[0], funds: .[1], date: .[2]})
   | map(. as $x | (if $x.date != "" then $mdone else $mtodo end) | part | fill($x)) | join("\n")) as $milestones
| ($m.payouts | map(map(@html) | {date: .[0], amount: .[1]})
   | map(. as $x | $payout | part | fill($x)) | join("\n")) as $payouts
| ($p | values) as $v0
# A funding page's address, already checked against the signed list.
# Its QR code is /qr/<address>.png, the signed list's own file.
# A donate-qr-code in the JSON is never used. Anything else stops the run.
| (if $stage != "fr" then ""
   elif ($v0.address | test("^[0-9A-Za-z]{95}$") | not) then error("\($file): no donation address")
   elif $qrs[0][$v0.address] != "/qr/\($v0.address).png" then error("\($file): no QR code")
   else $qrs[0][$v0.address] end) as $qr
| ($v0 + {segments: ($v0 | segments($segdone; $segtodo)), body: $m.body, qr: $qr, milestones_list: "", payouts_list: "",
          verify_link: ($verifylink | rtrimstr("\n")),
          tag_links: ($p | tag_links($labellink))}) as $v
| $tpl[$stage]
| fill($v)
# A Funding Required proposal at its goal shows "Fully funded" and no address.
# A design without that part still shows the box.
| region(if $stage == "fr" then "donate" else "funded" end;
    (if $stage != "fr" then $funded elif (($p.percentage // 0) | tonumber? // 0) >= 100 and $donatefunded != "" then $donatefunded else $donate end) | part | fill($v))
| region("milestones"; if $milestones == "" then $nom | part else $milestones end)
| region_if_there("payouts"; if $payouts == "" then $nop | part else $payouts end)
| region("count idea"; $cidea | part) | region("count fr"; $cfr | part)
| region("count wip"; $cwip | part) | region("count cp"; $ccp | part)
| region("filters"; $filters | part)
| region_if_there("onion"; $onion | part)
| "\u0001\($file)\n" + gsub("\u0001"; "")

# Every proposal page, in one run: the original's parts/proposal-<stage>.html, its {{slots}}
# filled, then its regions (donation box or funding, milestones, payouts) filled with the
# original's parts. Prints each page after a line "\u0001<file name>" (see ccs-front-bash.sh).
# Inputs: --slurpfile proposals, completed (ccs-bash's JSON), md (markdown.awk's lines), qrs (the QR
# codes' paths, by address);
# --rawfile fr, wip, cp (parts/proposal-*.html), donate, funded, donatefunded (or empty), mdone,
# mtodo, payout, nom, nop, segdone, segtodo, labellink (the other parts); cidea, cfr, cwip, ccp,
# filters (the sidebar's counts and tags, as on every other page).
include "common";

def part: rtrimstr("\n");

# Replace what is between <!-- ccs:NAME --> and <!-- /ccs:NAME -->, each there exactly once.
# Runs after the slots are filled; what it puts in is not looked at again.
def region($name; $html):
  ("<!-- ccs:\($name) -->") as $a | ("<!-- /ccs:\($name) -->") as $b
  | split($a) as $x
  | if ($x | length) != 2 then error("<!-- ccs:\($name) --> \($x | length - 1) times") else . end
  | ($x[1] | split($b)) as $y
  | if ($y | length) != 2 then error("<!-- /ccs:\($name) --> \($y | length - 1) times") else . end
  | $x[0] + $a + "\n" + $html + "\n" + $b + $y[1];

# The same for a region the original leaves out of some pages (the payouts: not on a funding
# page, where nothing is paid out yet): filled where its marker is, else the page stays as it is.
def region_if_there($name; $html):
  if contains("<!-- ccs:\($name) -->") then region($name; $html) else . end;

($md | map({key: .file, value: .}) | from_entries) as $byfile
| {fr: $fr, wip: $wip, cp: $cp} as $tpl
| paged($proposals; $completed) | .[0] as $stage | .[1] as $p
| ($p | page_file) as $file
| ($byfile[$file] // error("no proposal file \($file).md")) as $m
# the front matter's milestones and payouts are the proposal's own text: escaped here
| ($m.milestones | map(map(@html) | {name: .[0], funds: .[1], date: .[2]})
   | map(. as $x | (if $x.date != "" then $mdone else $mtodo end) | part | fill($x)) | join("\n")) as $milestones
| ($m.payouts | map(map(@html) | {date: .[0], amount: .[1]})
   | map(. as $x | $payout | part | fill($x)) | join("\n")) as $payouts
| ($p | values) as $v0
# a funding page's address, from ccs-bash's JSON (checked against the signed list), and its QR
# code, the image /qr/<address>.png ($qrs, ccs-front-bash.sh's qr_codes: the signed list's; a
# donate-qr-code in the JSON, as ccs-bash before v0.2.19 wrote, is never used). Anything else
# stops the run.
| (if $stage != "fr" then ""
   elif ($v0.address | test("^[0-9A-Za-z]{95}$") | not) then error("\($file): no donation address")
   elif $qrs[0][$v0.address] != "/qr/\($v0.address).png" then error("\($file): no QR code")
   else $qrs[0][$v0.address] end) as $qr
| ($v0 + {segments: ($v0 | segments($segdone; $segtodo)), body: $m.body, qr: $qr, milestones_list: "", payouts_list: "",
          verify_link: ($verifylink | rtrimstr("\n")),
          tag_links: ($p | tag_links($labellink))}) as $v
| $tpl[$stage]
| fill($v)
# a Funding Required proposal at its goal: the design's donate-funded part ("Fully funded", no
# address) in place of the donation box; a design without that part, the box
| region(if $stage == "fr" then "donate" else "funded" end;
    (if $stage != "fr" then $funded elif (($p.percentage // 0) | tonumber? // 0) >= 100 and $donatefunded != "" then $donatefunded else $donate end) | part | fill($v))
| region("milestones"; if $milestones == "" then $nom | part else $milestones end)
| region_if_there("payouts"; if $payouts == "" then $nop | part else $payouts end)
| region("count idea"; $cidea | part) | region("count fr"; $cfr | part)
| region("count wip"; $cwip | part) | region("count cp"; $ccp | part)
| region("filters"; $filters | part)
| region_if_there("onion"; $onion | part)
| "\u0001\($file)\n" + gsub("\u0001"; "")

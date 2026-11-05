# The list of one stage, from ccs-bash's JSON and the original's parts.
# Inputs: --arg stage (idea, fr, wip, cp); --slurpfile proposals, completed (ccs-bash's files);
# --rawfile card, empty, segdone, segtodo, labelpart (parts/card-<stage>.html, empty.html,
# segment-*.html, label.html as labelpart).
include "common";

{idea: $proposals[0][0], fr: $proposals[0][1], wip: $proposals[0][2], cp: $completed[0][0]}[$stage].proposals
| cards(.; $card; $empty; $segdone; $segtodo; $labelpart)

# The list of one stage, from ccs-bash's JSON and the original's parts.
# --arg stage: idea, fr, wip or cp.
# --slurpfile proposals, completed: ccs-bash's files.
# --rawfile card, empty, segdone, segtodo, labelpart: the parts.
include "common";

{idea: $proposals[0][0], fr: $proposals[0][1], wip: $proposals[0][2], cp: $completed[0][0]}[$stage].proposals
| cards(.; $card; $empty; $segdone; $segtodo; $labelpart)

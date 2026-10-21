# Builds the files ccs-front reads, same layout as the old ccs-back:
#   $out == "proposals": [Ideas, Funding Required, Work in Progress]
#   $out == "complete":  [Completed Proposals]
# Inputs (--slurpfile, so each is wrapped in an array): props, state, totals, qr, ideas.

$props[0] as $props | $state[0] as $state | $totals[0] as $totals | $qr[0] as $qr

| def proposal:
    ($state[.file] // {}) as $s
    | ($totals[$s.subaddr_index // -1 | tostring] // {atomic: 0, count: 0}) as $t
    | ($t.atomic / 1e12 * 10000 | round / 10000) as $raised
    | {
        name: (.title | @html),
        "donate-address": $s.address,
        "donate-qr-code": (if $s.address then "data:image/png;base64,\($qr[$s.subaddr_index | tostring])" else null end),
        "gitlab-url": ((.gitlab_url // $s.gitlab_url) | if . then @html else null end),
        "local-url": "/proposals/\(.file | sub("\\.md$"; "")).html",
        contributions: $t.count,
        milestones: .milestones,
        "milestones-completed": .done,
        "milestones-percentage": ([100, (.done * 100 / .milestones | floor)] | min),
        percentage: (if .amount > 0 then [100, ($raised / .amount * 100 | round)] | min else 0 end),
        amount: .amount,
        "amount-funded": $raised,
        author: (.author | @html),
        date: (if .ts > 0 then .ts | strftime("%B %-d, %Y") else null end)
      };

  def stage($name; $layout):
    {stage: $name, proposals: [$props[] | select(.layout == $layout)] | sort_by(-.ts) | map(proposal)};

  if $out == "proposals" then
    [{stage: "Ideas", proposals: $ideas[0]}, stage("Funding Required"; "fr"), stage("Work in Progress"; "wip")]
  else
    [stage("Completed Proposals"; "cp")]
  end

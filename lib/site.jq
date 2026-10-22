# Builds the files ccs-front reads, same layout as the old ccs-back:
#   $out == "proposals": [Ideas, Funding Required, Work in Progress]
#   $out == "completed-proposals": [Completed Proposals]
#   $out == "projects":  every proposal, in the order first seen (the /projects API)
# Inputs (--slurpfile, so each is wrapped in an array): props, state, funds, qr, ideas.
# All XMR amounts arrive ready to show from proposal_funds (lib/wallet.sh);
# no money arithmetic happens here, since jq numbers are doubles.

$props[0] as $props | $state[0] as $state | $funds[0] as $funds | $qr[0] as $qr

| def proposal:
    ($state[.file] // {}) as $s
    | $funds[.file] as $f
    | {
        name: (.title | @html),
        "donate-address": $s.address,
        "donate-qr-code": (if $s.address then "data:image/png;base64,\($qr[$s.subaddr_index | tostring])" else null end),
        "gitlab-url": ((.gitlab_url // $s.gitlab_url) | if . then @html else null end),
        "local-url": "/proposals/\(.file | sub("\\.md$"; "")).html",
        contributions: $f.count,
        milestones: .milestones,
        "milestones-completed": .done,
        "milestones-percentage": ([100, (.done * 100 / .milestones | floor)] | min),
        percentage: $f.percentage,
        amount: $f.amount,
        "amount-funded": $f.raised,
        "amount-pending": $f.pending,
        author: (.author | @html),
        date: (if .ts > 0 then .ts | strftime("%B %-d, %Y") else null end),
        "funding-required-date": ($s.funding_required_date | if . then fromdate | strftime("%B %-d, %Y") else null end)
      };

  def project:
    $funds[.file] as $f
    | {
        address: $state[.file].address,
        author: (.author | @html),
        contributions: $f.count,
        date: (if .ts > 0 then .ts | strftime("%B %-d, %Y") else null end),
        percentage_funded: $f.percentage,
        raised_amount: $f.raised,
        state: {fr: "FUNDING-REQUIRED", wip: "WORK-IN-PROGRESS", cp: "COMPLETED"}[.layout],
        target_amount: $f.amount,
        title: (.title | @html),
        filename: .file
      };

  def stage($name; $layout):
    {stage: $name, proposals: [$props[] | select(.layout == $layout)] | sort_by(-.ts) | map(proposal)};

  if $out == "proposals" then
    [{stage: "Ideas", proposals: $ideas[0]}, stage("Funding Required"; "fr"), stage("Work in Progress"; "wip")]
  elif $out == "completed-proposals" then
    [stage("Completed Proposals"; "cp")]
  else
    ($props | map({key: .file, value: .}) | from_entries) as $byfile
    | [$state | keys_unsorted[] | $byfile[.] // empty | project]
  end

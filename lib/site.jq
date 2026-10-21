# Builds the files ccs-front reads, same layout as the old ccs-back:
#   $out == "proposals": [Ideas, Funding Required, Work in Progress]
#   $out == "complete":  [Completed Proposals]
#   $out == "projects":  every proposal, in the order first seen (the /projects API)
# Inputs (--slurpfile, so each is wrapped in an array): props, state, totals, qr, ideas.

$props[0] as $props | $state[0] as $state | $totals[0] as $totals | $qr[0] as $qr

# 85 -> "85.0000": amounts are shown with 4 decimals, as ccs-back stores
# them as DECIMAL(8,4).
| def fixed4: (. * 10000 | round) as $n | "\($n / 10000 | floor).\("000\($n % 10000)" | .[-4:])";

  # Donations to a proposal. raised is rounded to 4 decimals before the
  # percentage is worked out, as ccs-back did.
  def funds:
    ($state[.file] // {}) as $s
    | ($totals[$s.subaddr_index // -1 | tostring] // {confirmed: 0, pending: 0, count: 0}) as $t
    | ($t.confirmed / 1e12 * 10000 | round / 10000) as $raised
    | {
        raised: $raised,
        pending: ($t.pending / 1e12),
        count: $t.count,
        percentage: (if .amount > 0 then [100, ($raised / .amount * 100 | round)] | min else 0 end)
      };

  def proposal:
    ($state[.file] // {}) as $s
    | funds as $f
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
        amount: (.amount | fixed4),
        "amount-funded": ($f.raised | fixed4),
        "amount-pending": $f.pending,
        author: (.author | @html),
        date: (if .ts > 0 then .ts | strftime("%B %-d, %Y") else null end),
        "funding-required-date": ($s.funding_required_date | if . then fromdate | strftime("%B %-d, %Y") else null end)
      };

  def project:
    funds as $f
    | {
        address: $state[.file].address,
        author: (.author | @html),
        contributions: $f.count,
        date: (if .ts > 0 then .ts | strftime("%B %-d, %Y") else null end),
        percentage_funded: $f.percentage,
        raised_amount: ($f.raised | fixed4),
        state: {fr: "FUNDING-REQUIRED", wip: "WORK-IN-PROGRESS", cp: "COMPLETED"}[.layout],
        target_amount: (.amount | fixed4),
        title: (.title | @html),
        filename: .file
      };

  def stage($name; $layout):
    {stage: $name, proposals: [$props[] | select(.layout == $layout)] | sort_by(-.ts) | map(proposal)};

  if $out == "proposals" then
    [{stage: "Ideas", proposals: $ideas[0]}, stage("Funding Required"; "fr"), stage("Work in Progress"; "wip")]
  elif $out == "complete" then
    [stage("Completed Proposals"; "cp")]
  else
    ($props | map({key: .file, value: .}) | from_entries) as $byfile
    | [$state | keys_unsorted[] | $byfile[.] // empty | project]
  end

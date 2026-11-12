# Builds the files ccs-front-bash reads, in the old ccs-back's layout:
#   $out == "proposals": [Ideas, Funding Required, Work in Progress]
#   $out == "completed-proposals": [Completed Proposals]
#   $out == "projects":  every proposal, in the order first seen (the /projects API)
# Inputs (--slurpfile, each wrapped in an array): props, state, funds, ideas.
# Amounts arrive as display text (lib/wallet.sh). No money arithmetic in jq: it uses doubles.

$props[0] as $props | $state[0] as $state | $funds[0] as $funds

# Links on the site: only plain https URLs (no javascript: and the like), HTML-escaped.
| def link: if type == "string" and test("^https://[^\\s\"'<>\\\\]+$") then @html else null end;

  # Escape like Liquid's `escape` (@html writes ' as &apos;). ccs-front matches its escaped
  # file name against this (docs/setup.md step 4).
  def liquid_escape: gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;") | gsub("\""; "&quot;") | gsub("'"; "&#39;");

  # Remove bidi controls from page text. They can display an address's halves in a different
  # order than written, so the web server's gate refuses them. Without this, one in a merged
  # proposal's title would stop its page from updating.
  def nobidi: gsub("[\u202a-\u202e\u2066-\u2069\u200e\u200f\u061c]"; "");

  def proposal:
    ($state[.file] // {}) as $s
    | $funds[.file] as $f
    | {
        name: (.title | nobidi | @html),
        "donate-address": $s.address,
        "gitlab-url": ((.gitlab_url // $s.gitlab_url) | link),
        "local-url": ("/proposals/\(.file | sub("\\.md$"; "")).html" | liquid_escape),
        contributions: $f.count,
        milestones: .milestones,
        "milestones-completed": .done,
        "milestones-percentage": ([100, (.done * 100 / .milestones | floor)] | min),
        percentage: $f.percentage,
        amount: $f.amount,
        "amount-funded": $f.raised,
        "amount-pending": $f.pending,
        # Amount still needed, counting pending donations, rounded up ("0.0000": fully funded)
        "amount-needed": $f.needed,
        author: (.author | nobidi | @html),
        date: (if .ts > 0 then .ts | strftime("%B %-d, %Y") else null end),
        "funding-required-date": ($s.funding_required_date | if . then fromdate | strftime("%B %-d, %Y") else null end),
        # For the feed: when it entered Funding Required, and when it was fully funded (UTC)
        "funding-required-at": $s.funding_required_date,
        "funded-at": $s.funded_date,
        tags: (.tags | map(nobidi | @html))
      };

  # "12.3400" -> 12.34, "5.0000" -> 5
  def xmr_number: (if test("\\.") then sub("0+$"; "") | sub("\\.$"; "") else . end) | tonumber;

  def project:
    $funds[.file] as $f
    | {
        address: $state[.file].address,
        author: (.author | nobidi | @html),
        contributions: $f.count,
        date: (if .ts > 0 then .ts | strftime("%B %-d, %Y") else null end),
        percentage_funded: $f.percentage,
        # Numbers, as the old ccs-back's /projects had them (readers add them up).
        # Made from the exact 4-decimal text with trailing zeros dropped first, so every jq
        # version prints the same digits (1.8 keeps the text as written, 1.6 prints the shortest).
        raised_amount: ($f.raised | xmr_number),
        state: {fr: "FUNDING-REQUIRED", wip: "WORK-IN-PROGRESS", cp: "COMPLETED"}[.layout],
        target_amount: ($f.amount | xmr_number),
        title: (.title | nobidi | @html),
        filename: .file,
        # The proposal's MR link, on whatever forge hosts the proposals (GitLab, Forgejo)
        gitlab_url: ((.gitlab_url // $state[.file].gitlab_url) | link)
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

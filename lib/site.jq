# Builds the files ccs-front-bash reads, the old ccs-back's layout:
#   $out == "proposals": [Ideas, Funding Required, Work in Progress]
#   $out == "completed-proposals": [Completed Proposals]
#   $out == "projects":  every proposal, in the order first seen (the /projects API)
# Inputs (--slurpfile, each wrapped in an array): props, state, funds, ideas.
# Amounts arrive ready to show (lib/wallet.sh): no money arithmetic in jq's doubles.

$props[0] as $props | $state[0] as $state | $funds[0] as $funds

# Links on the site: only plain https urls (not javascript: and the like), HTML-escaped.
| def link: if type == "string" and test("^https://[^\\s\"'<>\\\\]+$") then @html else null end;

  # As Liquid's `escape` (@html writes ' as &apos;): ccs-front matches its escaped file
  # name against this (docs/setup.md step 4).
  def liquid_escape: gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;") | gsub("\""; "&quot;") | gsub("'"; "&#39;");

  # Bidi controls go from what a page shows: they can show an address's halves in another order
  # than written, so the web server's gate refuses them (a merged proposal's title with one would
  # stop its page updating).
  def nobidi: gsub("[\u202a-\u202e\u2066-\u2069]"; "");

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
        # what would fund it now, pending counted, rounded up ("0.0000": nothing more needed)
        "amount-needed": $f.needed,
        author: (.author | nobidi | @html),
        date: (if .ts > 0 then .ts | strftime("%B %-d, %Y") else null end),
        "funding-required-date": ($s.funding_required_date | if . then fromdate | strftime("%B %-d, %Y") else null end),
        # (the feed's: when it went to Funding Required, and when its goal was raised; UTC)
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
        author: (.author | @html),
        contributions: $f.count,
        date: (if .ts > 0 then .ts | strftime("%B %-d, %Y") else null end),
        percentage_funded: $f.percentage,
        # numbers, as ccs-back's /projects has them (its readers add them up), from the exact
        # 4-decimal text, its trailing zeros dropped first (every jq then prints the same digits:
        # 1.8 keeps a number's text as written, 1.6 prints the shortest)
        raised_amount: ($f.raised | xmr_number),
        state: {fr: "FUNDING-REQUIRED", wip: "WORK-IN-PROGRESS", cp: "COMPLETED"}[.layout],
        target_amount: ($f.amount | xmr_number),
        title: (.title | @html),
        filename: .file,
        # the proposal's merge request, wherever the proposals are (GitLab, Forgejo): as the site's own
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

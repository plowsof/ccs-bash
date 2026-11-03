# The proposals' forge

The proposals live in a git repository on a forge: GitLab (gitlab.com, or another GitLab) or
Forgejo/Gitea. Both machines read it:
- **the backend:** its checkout for the proposals' files, and the forge's API for ideas (open
  merge requests) and their votes;
- **the web server's gate:** it fetches the repository itself, and checks each proposal's text
  and images against it.

## While the forge is down

Nothing needs doing for a few hours; the site keeps working.
- **The backend:** each run's `git pull` fails, which isn't counted as a failed run. The last
  checkout, ideas and votes stay. After `FORGE_HOURS` (`/etc/ccs/alert.conf`, default 6), IRC
  hears "GitLab/Forgejo hasn't answered for over Nh", and "answers again" when it does.
- **The gate:** it checks against its last fetch. A proposal merged or changed since is held back
  until a fetch works. After `FORGE_HOURS` (`/etc/ccs-gate/alert.conf`), IRC hears "the web
  server can't fetch the proposals repository since …".
- **Not possible meanwhile:** merging or changing a proposal, new ideas, votes, comments.

If it's down for days, or gone, move to another forge (below).

## What is only on the forge

Git itself is copied everywhere: the backend's checkout and the gate's fetch are full copies of
the repository. Merge requests, their comments and votes are only in the forge's database. They
are not backed up anywhere yet. A GitLab project export (`POST /projects/:id/export` in its API:
the repository, merge requests, comments and labels in one archive, importable into any GitLab)
kept on the backup machine would be one.

## Moving to another forge

GitLab (gitlab.com, or another GitLab) or Forgejo/Gitea (disroot, Codeberg): a public repository,
read without a token. The testnet moved from disroot's Forgejo to gitlab.com this way
([the testnet](testnet.md)). Paused (`docker compose stop pull`, then `ccs status`: no run going), copies kept, as root on
the backend:

1. **The API**, in the backend's `/etc/ccs/ccs.conf`:

   ```
   REPOSITORY_URL=https://gitlab.com/api/v4/projects/<id>              # GitLab: the project's number
   REPOSITORY_URL=https://git.disroot.org/api/v1/repos/<owner>/<repo>  # Forgejo or Gitea
   ```

   (`/api/v4/projects/` or `/api/v1/repos/` is what tells them apart.)

2. **The checkout**, so the compose's `pull` pulls from there: the same history, `remote set-url`;
   else a fresh clone in its place, of the branch the site runs:

   ```
   runuser -u ccs-git -- env HOME=/ git -C /var/lib/ccs/proposals \
       remote set-url origin https://git.disroot.org/<owner>/<repo>.git
   # or, the old one kept beside it:
   install -d -o ccs-git -g ccs-git -m 755 /var/lib/ccs/proposals.new
   runuser -u ccs-git -- env HOME=/ git clone -q --branch <branch> https://gitlab.com/<owner>/<repo>.git /var/lib/ccs/proposals.new
   mv /var/lib/ccs/proposals /var/lib/ccs/proposals.old && mv /var/lib/ccs/proposals.new /var/lib/ccs/proposals
   ```

3. **The merge request caches**, emptied: `rm -f /var/lib/ccs/state/ideas.cache
   /var/lib/ccs/state/merged-files.cache`. They are by merge request number, and the new forge's
   numbers start again: kept, its !1 would be the old forge's !1.

4. **The web server's gate**, `/etc/ccs-gate/proposals.conf`: `PROPOSALS_GIT` the new repository's
   git URL, `PROPOSALS_BRANCH` its branch (default `master`), and `LINK_HOSTS` the old forge's
   repository (host/path), so the proposals already linked to its merge requests keep their links.
   Without it, every page would be checked against the old repository.

5. **The containers** that mount the checkout, made again (a mount keeps the folder it was given):
   `docker compose up -d --force-recreate pull ccs-bash front`.

Then `docker compose start pull` and a run at once, `ccs proposal:process`. Ideas become the new forge's open merge or
pull requests, and newly merged proposals link to theirs; known ones keep their link in
`proposals.csv` (to rewrite them too:
`sed -i 's#https://repo.getmonero.org/monero-project/ccs-proposals/-/merge_requests/#https://git.disroot.org/<owner>/<repo>/pulls/#'`,
the loop paused, a copy kept, and the old host out of `LINK_HOSTS`). A proposal the new repository
doesn't have leaves the site: the gate takes its page off at the next push
([remove a proposal](troubleshooting.md#doing-things-by-hand)). The site's words ("GitLab", Submit Idea) are
ccs-front-hugo's. Going back: the old `REPOSITORY_URL`, checkout and `proposals.conf`, and the
caches emptied again.

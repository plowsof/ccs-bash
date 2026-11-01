# Python in ccs-bash

ccs-bash is bash, awk and jq, except in one place: the web server's gate,
[`contrib/ccs-receive`](../contrib/ccs-receive), which checks every push from the backend before
it goes live. Nothing else runs Python: not the backend (ccs-bash, ccs-front-bash), not the push or
the backups, not ccs-watch, and not the web server answering visitors (nginx serves static files).
Some test scripts (`tests/gate.sh`, `watch.sh`, `gate-image.sh`, `rrsync.sh`) use it too; they run
in CI and on a developer's machine, never on the servers.

## What it does there

About 485 lines, inline in `ccs-receive`, each block run as `python3 -I -c "$block"`:

| Block | Lines | What it checks |
|---|---|---|
| `pages_py` | 223 | every page is the design's, its regions filled only with the design's parts, a proposal's text as the proposals repository has it |
| `qrscan_py` | 99 | reads the QR codes in a page's and a proposal's images (libzbar, through ctypes) |
| `check_py` | 58 | Monero address checksums (Keccak), for the two below |
| `pixels_py` | 45 | a donation box's QR code is, pixel for pixel, qrencode's of its address |
| `scan_py` | 33 | every address in the pages and JSON, also spaced out, split or drawn with look-alikes, is the wallet's or allowed |
| `json_py` | 27 | `projects.json` reads as JSON |

These are what bash and awk do badly or unsafely: decoding images, checksums over bytes, and
matching whole pages with Unicode rules. Anything that can be plain text matching is awk (the
feed check, `feed_awk`, is).

## Who can reach it

Python never sees a visitor. Its only input is a push from the backend:

- **one SSH key**, the backend's, `from=` its address, `restrict`, and a fixed command
  (`ForceCommand=/usr/local/bin/ccs-receive`): it can't open a shell or run anything else;
- **only the files in that push** (and the gate's own read-only config: the signed list, the
  design, the proposals it fetched itself).

So a Python vulnerability matters only if the backend is compromised first and then sends files
crafted to exploit it while they are checked. On the old PHP front end, one HTTP request from
anyone reached the interpreter.

## What limits it

- **`python3 -I`**: no `PYTHON*` environment variables, no user site-packages, not the current
  folder: it runs the standard library and the block, nothing else.
- **Only the standard library** (plus libzbar, loaded by `qrscan_py`): nothing is installed with
  pip; the gate's image has no pip and no `site-packages` at all.
- **Limits:** a time limit on every run (`timeout`, 20 seconds to 5 minutes); a file over 8 MB
  isn't read; the image decoders get 1 GB of address space and skip an image over 40 million
  pixels before decoding it; the container has 2 GB and 256 processes.
- **No root**: sshd hands the push to the `ccs-data` account; Python runs as it. The container
  is read-only but for its own folders, with no capabilities beyond sshd's and
  `no-new-privileges`.
- **Failing closed**: a crash, a timeout or an error is a page or file that didn't pass: it is
  held back and its last good copy stays live.
- **No XML or HTML parser**: pages and the feed are matched as text against the exact form the
  design and ccs-front-bash write, so the parsers' usual attacks (entities, nesting) don't apply.

What it does **not** stop: code run through a Python vulnerability runs as `ccs-data`, which can
write the live site's files (that is its job), and the gate's container uses the host's network
(for the proposals' fetch and the alerts). A compromised backend plus a Python exploit could
therefore change the site, as a compromised gate could. Hence: keep Python patched.

## Keeping it patched

- **Docker (the web server compose):** the gate's image pins StageX's Python (`container/images`,
  `python`, 3.14, supported until 2030) by digest, with its signatures checked
  ([image.md](image.md)). A Python security release is a StageX pin refresh like any other:
  `container/update-images.sh` and `update-sigs.sh`, a new ccs-bash release, the web server switched to its gate image.
- **The host setup:** the gate uses the distribution's `python3`; its security updates
  (unattended-upgrades on Debian and Ubuntu) cover it.
- **Watch for:** Python security releases (python.org's security announcements) and libzbar's
  CVEs; either is a reason to release.

Removing Python entirely would mean doing QR decoding, pixel comparison and checksums with other
tools (zbarimg, a C helper), which are dependencies of their own; for now it stays, contained to
the gate.

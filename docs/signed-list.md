# The signed subaddress list

Every donation address the site shows must be one of the live wallet's first 15,000
subaddresses, and its QR code that list's own image of it. The list is made once, from the
wallet's public address and view key, signed by a Core Team member, and installed by hand on both
machines: ccs-front-bash leaves any other address off the site, and the web server's gate holds
it back. Visitors check an address against the wallet itself on the Verify page.

The tools are ccs-front-bash's ([its `tools/`](https://github.com/plowsof/ccs-front-bash/tree/v0.1.26/tools),
v0.1.26), run from a checkout of it: `make-subaddresses.sh`, `make-qr.sh`, `sign-subaddresses.sh`
and `verify-subaddresses.sh`. Each wallet's list is kept in this repository,
`subaddresses/<wallet>/` (the mainnet's: [`subaddresses/ccs2/`](../subaddresses/ccs2/)), with its
signature, key, `.pin`, view key file and `wallet.txt`; its QR codes aren't (11.5 MB): they are
made again from the list (step 1).

## The files

| File | What it is | Backend `/etc/ccs-front/` | Web server `/etc/ccs-gate/` |
|---|---|---|---|
| `subaddresses.txt` | `index address` lines, 0 to 14,999; line 0 the main address | yes | yes |
| `subaddresses.txt.asc`, `.key.asc` | the signature, the signer's public key | yes | yes |
| `subaddresses.txt.pin` | `sha256 <the list's>`, `key <the signer's fingerprint>`, `qr <the sha256 of .qr.sha256>`: what each machine trusts | yes | yes |
| `subaddresses.txt.qr/` | `<address>.png` for each address, `qrencode -s 10 "monero:<address>"` | yes | yes: the site's QR codes, each taken only as its sum |
| `subaddresses.txt.qr.sha256` | each QR code's sha256, in the list's order | yes | yes: each `qr/` file the site shows must be one of these |
| `subaddresses.txt.viewkey` | the view key, and where it was published (`source`, `source-text`) | yes | yes |
| `list-signers` | the fingerprints you accept, written by you, never one that came with the list | yes | yes |

Each file root-owned, 644 (the folder 755). Each run and each push checks the list and the QR
sums against the `.pin`: another list, or a missing file, stops the run (the backend) or refuses
the push (the web server). Changing them needs root there.

## 1. Made, on an offline machine

A **Core Team member** makes it. The script asks for the wallet's main address and view key (both
public) and makes the subaddresses in a view-only copy that an offline `monero-wallet-rpc` holds
in a temporary folder (no spend key, no daemon), about a minute for 15,000; then each one's QR
code (`make-qr.sh`, needs qrencode), about 30 s more:

```
tools/make-subaddresses.sh /path/to/monero-wallet-rpc 15000 subaddresses.txt   # --testnet for testnet
```

Check it before signing: line 0 is the main address, and the subaddresses the wallet has already
made are its first lines:

```
head -n 1 subaddresses.txt                         # 0 <the main address, WALLET_ADDRESS>
curl -s --digest -u user:pass http://127.0.0.1:18082/json_rpc \
    -d '{"jsonrpc":"2.0","id":0,"method":"get_address","params":{"account_index":0}}' \
    | jq -r '.result.addresses | sort_by(.address_index)[] | "\(.address_index) \(.address)"' > made.txt
head -n "$(wc -l < made.txt)" subaddresses.txt | cmp - made.txt && echo "the wallet's own"
```

A list kept in `subaddresses/<wallet>/` (or one made before the QR codes were): its QR codes are
made again from it, `tools/make-qr.sh subaddresses.txt`; the `.pin`'s `qr` line says what they
must be (one made before them: add the line by hand, `echo "qr $(sha256sum < subaddresses.txt.qr.sha256
| cut -d' ' -f1)" >> subaddresses.txt.pin`). qrencode 4.1.1 writes the same bytes on Debian and
Ubuntu as in StageX's.

## 2. Signed with their own key

As the Monero repository publishes it ([utils/gpg_keys/](https://github.com/monero-project/monero/tree/master/utils/gpg_keys)):
for the mainnet, binaryFate (`81AC 591F E9C4 B65C 5806  AFC3 F0AF 4D46 2A0B DF92`) or luigi1111
(`8777 AB8F 778E E894 87A2  F8E7 F4AC A018 3641 E010`):

```
SIGNING_KEY=<the signer's fingerprint> tools/sign-subaddresses.sh subaddresses.txt
```

It writes `.asc`, `.key.asc` and `.pin`. The QR codes aren't signed: they are the list's, and
anyone remakes them from it (step 4 does). Without `SIGNING_KEY` it signs with a key made for this
and destroyed after (the testnet's): that binds the file, not a person.

## 3. Published and reproduced

The signer posts the list's sha256, the `qr` sha256 and the fingerprint where the address and view
key were published (mainnet: monero-project/meta #935). Two contributors make it themselves from
the same public data (step 1) and post the same two sha256.

## 4. Checked, on each machine, then installed

With your own `list-signers` (fingerprints as `gpg --show-keys binaryfate.asc` shows Monero's
copies), and the signer's key as you got it yourself, so a revocation is known (without
`SIGNER_KEYS`, the `.key.asc` that came with the list is used, which whoever brings the list chose):

```
cat > /etc/ccs-front/list-signers <<'SIGNERS'
81AC591FE9C4B65C5806AFC3F0AF4D462A0BDF92  # binaryFate (monero-project/monero utils/gpg_keys)
8777AB8F778EE89487A2F8E7F4ACA0183641E010  # luigi1111 (monero-project/monero utils/gpg_keys)
SIGNERS
curl -fsSLo signer.asc https://raw.githubusercontent.com/monero-project/monero/master/utils/gpg_keys/<signer>.asc
SIGNER_KEYS=signer.asc tools/verify-subaddresses.sh subaddresses.txt /etc/ccs-front/list-signers <WALLET_ADDRESS>
```

OK means: the list is its `.pin`'s, signed by a key in `list-signers`, its lines 0, 1, 2…, line 0
`WALLET_ADDRESS`; its QR codes the `.pin`'s, one per address, each remade there with qrencode and
the same, byte for byte (needs qrencode; about 30 s). Compare the sha256 with the published ones.
It can't know the key was revoked since: check Monero's copy, fetched fresh:

```
curl -fsSO https://raw.githubusercontent.com/monero-project/monero/master/utils/gpg_keys/luigi1111.asc   # or binaryfate.asc
gpg --show-keys --with-colons luigi1111.asc | awk -F: '$1 == "pub" { print ($2 == "r" ? "REVOKED" : "not revoked") }'
```

A revoked key: don't install the list; ask the Core Team for one signed again.

Run the check on a computer you trust, with qrencode: the offline machine the list was made on, or
your own; not the backend, which could print OK over a list it swapped. Then copy the files to
each machine as the table above says, and check the QR codes there against their sums
(`cd subaddresses.txt.qr && sha256sum -c --quiet ../subaddresses.txt.qr.sha256`); the web
server checks the list's files too ([the web server](web-server.md), "What is installed by hand"):
a taken-over backend would bring both a list and the sums it is compared with.

The view key file, beside them, for the Verify page (for the mainnet):

```
62ad19781466882d8df0ae85743abcc5c8ef81e52e051e7cc56fe3c610d18001
source https://github.com/monero-project/meta/issues/935#issuecomment-1867257410
source-text shared by luigi1111 here
```

## What each run then does

ccs-front-bash checks the list and its QR sums against the `.pin` (another list stops the run),
then every address the site would show: a funding-required proposal or a `/projects` entry whose
address isn't on it is left off (`warning: left off the site: …`), the rest is made, and the run
exits 3. Each donation box shows its address, its QR code `qr/<address>.png` (the list's file) and
a link to `/verify/`. The web server builds the site the same way from its own copy, and checks
every page's addresses and QR files against it ([where an address is checked](reviewing.md#where-an-address-is-checked-against-the-signed-list)).

## A new list

Near index 15,000, make a longer list the same way: its first lines are the old one
(`head -n 15000 new | cmp - old`), and so are its QR codes' sums. A new wallet: its own list
([retiring a wallet](handover.md#retiring-a-wallet)).

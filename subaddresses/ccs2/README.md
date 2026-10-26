# CCS2: the mainnet CCS wallet's subaddresses

The first 15,000 subaddresses of the CCS2 wallet (main address `41hzbgqgkrYi…`, line 0), made with ccs-front-bash's
`tools/make-subaddresses.sh` from its public address and view key (luigi1111,
[meta #935](https://github.com/monero-project/meta/issues/935#issuecomment-1867257410)): anyone can
make the same file and compare its sha256 (`663c054c5d3ae96390302e1dee8bf0b823347087c64e79f1a4513b4114283d60`).

**Signed with a throwaway placeholder key** (plowsof's, `0C45 A05D 19D1 7528 28B1  1EBE CA7F 6D97 C310 3FC8`,
destroyed after signing), until a Core Team member signs it with their own key
([handover](../../docs/handover.md#4-the-signed-subaddress-list), step 4): then `.asc`, `.key.asc`,
`.pin` and `list-signers` are replaced, the list itself stays the same.

Installed on the backend (`/etc/ccs-front/`) and the web server (`/etc/ccs-gate/`) after
`tools/verify-subaddresses.sh subaddresses.txt list-signers <WALLET_ADDRESS>` says OK.

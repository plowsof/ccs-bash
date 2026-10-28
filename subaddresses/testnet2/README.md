# testnet2: the testnet CCS wallet's subaddresses, since 2026-10-28

The first 15,000 subaddresses of the testnet CCS wallet since the rehearsal of [retiring a
wallet](../../docs/handover.md#retiring-a-wallet) on https://ccs.monerodevs.org (main address
`9zSQntmDBFiN…`, line 0; the wallet before it: [testnet](../testnet/README.md), retired), made with
ccs-front-bash's `tools/make-subaddresses.sh --testnet` (v0.1.20; sha256
`9704373d2e060376669e771e9fdca21686b7412371447686100743fbd4150c88`), signed with a throwaway key
(`17B5 B07C B99B 6E75 C5B7  586A 2904 5FD6 3DF3 09E4`, destroyed after signing): checked with a
`list-signers` you write yourself with that fingerprint (none comes with the list).

`wallet.txt` states the wallet's address and view key together (a view-only wallet needs both);
the Verify page links to it.

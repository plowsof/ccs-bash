# ccs1: the retired CCS1 wallet

CCS1 is retired (docs/handover.md, "Retiring a wallet"): no page shows its addresses, so it has no
subaddress list. `wallet.txt` states its primary address and view key together (a view-only wallet
needs both), so anyone can rebuild `retired/ccs1.csv` with `contrib/retire-wallet` and check the
totals. Taken from a view-only copy of the wallet; **unsigned for now**: for luigi1111 to confirm
and sign (`gpg --clearsign wallet.txt`, giving `wallet.txt.asc`), as for CCS2.

# testnet: the testnet CCS wallet's subaddresses

The first 15,000 subaddresses of the testnet CCS wallet (https://ccs.monerodevs.org; main address
`9u9HeEyjQurJ…`, line 0), made with ccs-front-bash's `tools/make-subaddresses.sh --testnet`
(sha256 `25e665a9571d7d8321942d5347c4f341e3980903214f9c805b5506e09807c49b`), signed with a
throwaway key (`1115 3446 F53A 2911 E6D8  698E F3E9 06A1 AA0A 4224`, destroyed after signing):
checked with a `list-signers` you write yourself with that fingerprint (none comes with the list).

`wallet.txt` states the wallet's address and view key together (a view-only wallet needs both);
the Verify page links to it.

Its QR codes, the files the site shows (`qr/<address>.png`), aren't kept here (11.5 MB): make them
with ccs-front-bash's `tools/make-qr.sh subaddresses.txt` (`subaddresses.txt.qr/` and their sums,
`subaddresses.txt.qr.sha256`, sha256 `359ba2c8936a9f775125195836546a9a9b711eba0bcb4791848cad6b91e6593d`: the `.pin`'s `qr` line, added by hand when
the QR codes became the list's files; `verify-subaddresses.sh` remakes and checks them).

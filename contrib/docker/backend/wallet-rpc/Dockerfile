# monero-wallet-rpc for the backend's compose (contrib/docker/backend): getmonero.org's own
# release binary, the one image that isn't StageX (monero isn't packaged there, and the release is
# built for glibc). Its archive is checked against hashes.txt (kept here, as getmonero.org signed
# it), whose signature must be binaryFate's key, by fingerprint, as the monero repository has it
# at the release's tag. Only monero-wallet-rpc goes into the image; it runs as a numeric user.
# A new release: its hashes.txt here, MONERO_VERSION and MONERO_SHA256 below.

ARG MONERO_VERSION=v0.18.5.4
ARG MONERO_SHA256=ba2928962c101b609434bf8c1b43ad59ebe96c5525977284ca599d8bf0f02d10

FROM debian@sha256:99c0b25c46d0214d5a2091092e7908907dcaecd6a962cde0ac700acee222b6f3 AS check
ARG MONERO_VERSION
ARG MONERO_SHA256
RUN apt-get update -qq && apt-get install -qq -y --no-install-recommends gpg gpg-agent bzip2 > /dev/null
ADD --checksum=sha256:7dcb19c87d41a4399b4877054111f7dbfd30531545678bc2be218bd56903904c \
    https://raw.githubusercontent.com/monero-project/monero/${MONERO_VERSION}/utils/gpg_keys/binaryfate.asc /check/binaryfate.asc
ADD --checksum=sha256:${MONERO_SHA256} \
    https://downloads.getmonero.org/cli/monero-linux-x64-${MONERO_VERSION}.tar.bz2 /check/monero.tar.bz2
COPY hashes.txt /check/hashes.txt
RUN set -e; cd /check; export GNUPGHOME=/check/gpg; mkdir -m 700 "$GNUPGHOME" \
    && gpg -q --import binaryfate.asc \
    && gpg --status-fd 1 --verify hashes.txt 2> /dev/null | grep -q '^\[GNUPG:\] VALIDSIG 81AC591FE9C4B65C5806AFC3F0AF4D462A0BDF92 ' \
    && grep -qx "${MONERO_SHA256}  monero-linux-x64-${MONERO_VERSION}.tar.bz2" hashes.txt \
    && echo "${MONERO_SHA256}  monero.tar.bz2" | sha256sum -c - \
    && tar -xjf monero.tar.bz2 && install -D -m 755 monero-x86_64-linux-gnu-${MONERO_VERSION}/monero-wallet-rpc /out/usr/local/bin/monero-wallet-rpc

FROM debian@sha256:99c0b25c46d0214d5a2091092e7908907dcaecd6a962cde0ac700acee222b6f3
COPY --from=check /out/ /
# only a default: compose runs it as the host's wallet user
USER 10003:10003
ENTRYPOINT ["/usr/local/bin/monero-wallet-rpc"]

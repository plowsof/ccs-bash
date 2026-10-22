# The ccs-bash image. Built by build.sh with --network none: nothing is downloaded here.
# The base image is pinned by digest (base-image), the .deb files are the ones in
# deps.lock, fetched beforehand by fetch.sh and checked again below.
ARG BASE=set-by-build.sh
FROM ${BASE}

COPY container/deps.lock container/verify.sh /tmp/pin/
COPY container/debs/ /tmp/pin/debs/
RUN bash /tmp/pin/verify.sh /tmp/pin/deps.lock /tmp/pin/debs \
    && dpkg -i /tmp/pin/debs/*.deb \
    && rm -rf /tmp/pin

COPY ccs-back.sh /opt/ccs-bash/
COPY lib/ /opt/ccs-bash/lib/
RUN useradd --uid 10001 --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin ccs

# Run as the host's ccs user (docker run --user), see README.
USER ccs
ENTRYPOINT ["/opt/ccs-bash/ccs-back.sh"]
CMD ["/etc/ccs/ccs.conf"]

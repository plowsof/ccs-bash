# The ccs-bash image. Built by build.sh with --network none: nothing is downloaded here.
# The base image is pinned by digest (base-image), the .deb files are the ones in
# deps.lock, fetched beforehand by fetch.sh and checked again below.
#
# Reproducible: the same commit gives the same image hash. build.sh passes the commit's
# time as SOURCE_DATE_EPOCH; every file time after it is set to it, the logs and caches
# that record when the build ran are removed, and the result is copied into an empty
# image as one layer, so no layer holds the time of the build. There is no user account
# (its "password changed" date would be the build day): the image runs as a numeric user.
ARG BASE=set-by-build.sh
FROM ${BASE} AS build
ARG SOURCE_DATE_EPOCH

# The .deb files are mounted, not copied, so they never end up in a layer.
RUN --mount=type=bind,source=container,target=/pin \
    bash /pin/verify.sh /pin/deps.lock /pin/debs \
    && dpkg -i /pin/debs/*.deb \
    && rm -f /var/log/dpkg.log /var/log/alternatives.log /var/cache/ldconfig/aux-cache

COPY ccs-back.sh /opt/ccs-bash/
COPY lib/ /opt/ccs-bash/lib/
# Same modes and times whatever the checkout's umask and file times were.
RUN chmod 755 /opt/ccs-bash /opt/ccs-bash/lib /opt/ccs-bash/ccs-back.sh && chmod 644 /opt/ccs-bash/lib/* \
    && find /opt/ccs-bash -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +
# (/proc, /sys, /dev and /etc/hosts, hostname, resolv.conf are mounted in by docker.)
RUN find / -xdev \( -path /proc -o -path /sys -o -path /dev \
        -o -path /etc/hosts -o -path /etc/hostname -o -path /etc/resolv.conf \) -prune \
        -o -newermt "@$SOURCE_DATE_EPOCH" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +

FROM scratch
COPY --from=build / /
ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# Run as the host's ccs user (docker run --user), see README; this is only the default.
USER 10001:10001
ENTRYPOINT ["/opt/ccs-bash/ccs-back.sh"]
CMD ["/etc/ccs/ccs.conf"]

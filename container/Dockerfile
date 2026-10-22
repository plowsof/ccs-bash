# The ccs-bash image, from StageX packages: built from source by StageX, starting from a
# tiny bootstrap, and signed by several people who rebuilt them. Every StageX image is
# pinned by digest in container/images and handed in by build.sh as a named build context
# (FROM toolchain, COPY --from=bash, ...). Built with --network none: nothing is downloaded here.
#
# A pinned image: the same commit gives the same image hash. build.sh passes the commit's
# time as SOURCE_DATE_EPOCH; every file time after it is set to it, and the result is
# copied into an empty image as one layer, so no layer holds the time of the build.
# There is no user account: the image runs as a numeric user.

# qrencode, built from source with PNG output: StageX's own is built without libpng.
FROM toolchain AS qrencode
COPY --from=libpng / /
COPY --from=zlib / /
# bash for verify.sh (the toolchain only has busybox sh)
COPY --from=bash / /
COPY --from=ncurses / /
RUN --mount=type=bind,source=container,target=/pin \
    bash /pin/verify.sh /pin/sources.lock /pin/sources \
    && tar -xzf /pin/sources/v4.1.1.tar.gz -C / \
    && cd /libqrencode-4.1.1 \
    && autoreconf -fi \
    && ./configure --prefix=/usr --with-tools \
    && make \
    && make DESTDIR=/rootfs install \
    && rm -rf /rootfs/usr/include /rootfs/usr/lib/pkgconfig /rootfs/usr/share /rootfs/usr/lib/*.a /rootfs/usr/lib/*.la

# Everything ccs-bash runs, and nothing else.
FROM scratch AS assemble
ARG SOURCE_DATE_EPOCH
COPY --from=filesystem / /
COPY --from=musl / /
COPY --from=bash / /
COPY --from=ncurses / /
COPY --from=coreutils / /
COPY --from=findutils / /
COPY --from=gawk / /
COPY --from=util-linux / /
COPY --from=ca-certificates / /
COPY --from=curl / /
COPY --from=openssl / /
COPY --from=libzstd / /
COPY --from=zlib / /
COPY --from=libpng / /
COPY --from=jq / /
COPY --from=qrencode /rootfs/ /
COPY ccs-back.sh /opt/ccs-bash/
COPY lib/ /opt/ccs-bash/lib/
# There is no /bin/sh in this image (nothing needs one), so run the step below with bash.
SHELL ["/usr/bin/bash", "-c"]
# Same modes and times whatever the checkout's umask and file times were, and the commit's
# time on everything made during this build. (/proc, /sys, /dev and /etc/hosts, hostname,
# resolv.conf are mounted in by docker.)
# StageX packages also carry what only compiling needs: headers, static libraries, manuals.
RUN rm -rf /usr/include /usr/lib/pkgconfig /usr/lib/*.a /usr/share/man /usr/share/doc /usr/share/info \
    && chmod 755 /opt/ccs-bash /opt/ccs-bash/lib /opt/ccs-bash/ccs-back.sh && chmod 644 /opt/ccs-bash/lib/* \
    && find /opt/ccs-bash -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} + \
    && find / -xdev \( -path /proc -o -path /sys -o -path /dev \
        -o -path /etc/hosts -o -path /etc/hostname -o -path /etc/resolv.conf \) -prune \
        -o -newermt "@$SOURCE_DATE_EPOCH" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +

FROM scratch AS image
# /dev, /proc and /sys are made by docker for each container (here they were only mount
# points for the step above, with that moment's time on them).
COPY --exclude=dev --exclude=proc --exclude=sys --from=assemble / /
ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# Run as the host's ccs user (docker run --user), see README; this is only the default.
USER 10001:10001
ENTRYPOINT ["/opt/ccs-bash/ccs-back.sh"]
CMD ["/etc/ccs/ccs.conf"]

# For CI: the image plus what the tests use (sed, grep, diff).
FROM image AS test
COPY --from=sed / /
COPY --from=grep / /
COPY --from=diffutils / /

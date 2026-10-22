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

# Everything ccs-bash runs, and nothing else. busybox gives the small tools (env, date,
# mktemp, base64, xargs, awk, flock, sed, grep, diff, ...) in one package; bash runs the scripts.
FROM scratch AS tree
COPY --from=filesystem / /
COPY --from=musl / /
COPY --from=busybox / /
COPY --from=bash / /
COPY --from=ncurses / /
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

# Tidy a copy of that tree with the toolchain's busybox: drop what only compiling needs
# (headers, static libraries, manuals), fix the modes of our files whatever the checkout's
# umask was, and give every file the commit's time.
FROM toolchain AS fix
ARG SOURCE_DATE_EPOCH
COPY --from=tree / /rootfs/
RUN cd /rootfs \
    && rm -rf usr/include usr/lib/pkgconfig usr/lib/*.a usr/share/man usr/share/doc usr/share/info \
    && chmod 755 opt/ccs-bash opt/ccs-bash/lib opt/ccs-bash/ccs-back.sh && chmod 644 opt/ccs-bash/lib/* \
    && find . -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +

FROM scratch AS image
COPY --from=fix /rootfs/ /
ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# Run as the host's ccs user (docker run --user), see README; this is only the default.
USER 10001:10001
ENTRYPOINT ["/opt/ccs-bash/ccs-back.sh"]
CMD ["/etc/ccs/ccs.conf"]

# The ccs-bash image. StageX images (container/images, signatures checked) come in from
# build.sh as named contexts (FROM toolchain, COPY --from=bash). No network in the steps.
# Same commit, same hash: every file gets the commit's time (SOURCE_DATE_EPOCH) and the
# result is one layer in an empty image. No user account: it runs as a numeric user.

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

# busybox with only the applets in busybox-applets (and their options, like readlink -f).
# The toolchain's cc is clang.
FROM toolchain AS busybox
COPY --from=bash / /
COPY --from=ncurses / /
# no build time or date in the binary
ENV KCONFIG_NOTIMESTAMP=1
RUN --mount=type=bind,source=container,target=/pin \
    bash /pin/verify.sh /pin/sources.lock /pin/sources \
    && tar -xjf /pin/sources/busybox-1.38.0.tar.bz2 -C / \
    && cd /busybox-1.38.0 \
    && make HOSTCC=cc CC=cc allnoconfig > /dev/null \
    && for applet in $(grep -v '^#' /pin/busybox-applets); do \
        config=CONFIG_$(echo "$applet" | tr 'a-z-' 'A-Z_'); \
        grep -q "^# $config is not set$" .config || { echo "no applet $applet" >&2; exit 1; }; \
        sed -i "s/^# $config is not set$/$config=y/" .config; \
        sed -i "s/^# \(CONFIG_FEATURE_${config#CONFIG_}_[A-Z0-9_]*\) is not set$/\1=y/" .config; \
    done \
    && sed -i "s/^# CONFIG_LONG_OPTS is not set$/CONFIG_LONG_OPTS=y/" .config \
    && yes "" | make HOSTCC=cc CC=cc oldconfig > /dev/null \
    && make HOSTCC=cc CC=cc > /dev/null \
    && install -D -m 755 busybox /rootfs/usr/bin/busybox \
    && for applet in $(grep -v '^#' /pin/busybox-applets); do \
        ln -s busybox "/rootfs/usr/bin/$applet"; \
        ! "/rootfs/usr/bin/$applet" --help 2>&1 | grep -q "applet not found" || { echo "$applet not built" >&2; exit 1; }; \
    done

# Everything ccs-bash runs, and nothing else. bash runs the scripts.
FROM scratch AS tree
COPY --from=filesystem / /
COPY --from=musl / /
COPY --from=busybox /rootfs/ /
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

# Drop headers, static libraries and manuals, fix our files' modes (whatever the umask),
# give every file the commit's time.
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
# only a default: ccs-bash-run passes the host's ccs user (docs/setup.md step 3)
USER 10001:10001
ENTRYPOINT ["/opt/ccs-bash/ccs-back.sh"]
CMD ["/etc/ccs/ccs.conf"]

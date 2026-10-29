# The gate's image: the web server's side (contrib/docker/web): sshd, the gate (ccs-receive), the
# backup receiver (ccs-backup-receive) and what they run. Built as the ccs-bash image is
# (container/build.sh ccs-gate gate.Dockerfile): StageX images by digest (container/images,
# signatures checked), sources by sha256 (sources.lock), no network in the steps, every file the
# commit's time, one layer in an empty image. GNU userland, as the gate was written and tested
# for (Debian's); QR codes read by libzbar (built here, without ImageMagick: StageX publishes no
# zbar) on pixels the formats' own libraries decode.

# libzbar alone, as StageX's user/zbar recipe builds its libzbar: no image library, no video, no
# X, no bindings; zbarimg and zbarcam aren't built (they need ImageMagick, video). One fix: its
# movedelta() steps the pointer back by adding (uintptr_t)(dy)*w for a negative dy, undefined
# behaviour that gcc happens to wrap and clang (this toolchain's) doesn't: every scan crashed.
# Signed arithmetic instead; the build stops if the line isn't there to change.
FROM toolchain AS zbar
ARG SOURCE_DATE_EPOCH
COPY --from=bash / /
COPY --from=ncurses / /
RUN --mount=type=bind,source=container,target=/pin \
    bash /pin/verify.sh /pin/sources.lock /pin/sources \
    && tar -xzf /pin/sources/0.23.93.tar.gz -C / \
    && cd /zbar-0.23.93 \
    && sed -i 's/p += (dx) + ((uintptr_t)(dy)\*w); \\/p += (intptr_t)(dx) + (intptr_t)(dy) * (intptr_t)w; \\/' zbar/img_scanner.c \
    && grep -q 'p += (intptr_t)(dx) + (intptr_t)(dy) \* (intptr_t)w;' zbar/img_scanner.c \
    && autoreconf -fi > /dev/null \
    && CFLAGS="-O2 -ffile-prefix-map=/zbar-0.23.93=." ./configure -q --prefix=/usr --disable-nls --disable-video \
        --disable-doc --without-x --without-xshm --without-dbus --without-jpeg --without-imagemagick \
        --without-graphicsmagick --without-napi --without-gtk --without-gir --without-python --without-qt \
        --without-java --without-v4l --disable-static \
    && make -s > /dev/null \
    && make -s DESTDIR=/rootfs install > /dev/null \
    && find /rootfs -type f ! -name 'libzbar.so*' -delete && find /rootfs -type l ! -name 'libzbar.so*' -delete

# qrencode, built from source with PNG output (StageX's own is built without libpng), as
# ccs-front-bash's image builds it: the same version and options, so the same QR codes, pixel for
# pixel, as the backend's (the gate compares them)
FROM toolchain AS qrencode
COPY --from=libpng / /
COPY --from=zlib / /
COPY --from=bash / /
COPY --from=ncurses / /
RUN --mount=type=bind,source=container,target=/pin \
    bash /pin/verify.sh /pin/sources.lock /pin/sources \
    && tar -xzf /pin/sources/v4.1.1.tar.gz -C / \
    && cd /libqrencode-4.1.1 \
    && autoreconf -fi > /dev/null \
    && ./configure -q --prefix=/usr --with-tools \
    && make -s > /dev/null \
    && make -s DESTDIR=/rootfs install > /dev/null \
    && rm -rf /rootfs/usr/include /rootfs/usr/lib/pkgconfig /rootfs/usr/share /rootfs/usr/lib/*.a /rootfs/usr/lib/*.la

FROM scratch AS tree
COPY --from=filesystem / /
COPY --from=musl / /
COPY --from=bash / /
COPY --from=ncurses / /
COPY --from=ca-certificates / /
COPY --from=curl / /
COPY --from=openssl / /
COPY --from=libzstd / /
COPY --from=zlib / /
COPY --from=jq / /
COPY --from=git / /
COPY --from=rsync / /
COPY --from=openssh / /
COPY --from=xxhash / /
COPY --from=python / /
COPY --from=libffi / /
COPY --from=coreutils / /
COPY --from=findutils / /
COPY --from=grep / /
COPY --from=pcre2 / /
COPY --from=sed / /
COPY --from=gawk / /
COPY --from=diffutils / /
COPY --from=tar / /
COPY --from=util-linux /usr/bin/flock /usr/bin/flock
COPY --from=acl / /
COPY --from=attr / /
COPY --from=libpng / /
COPY --from=libjpeg / /
COPY --from=giflib / /
COPY --from=qrencode /rootfs/ /
COPY --from=zbar /rootfs/ /
COPY contrib/ccs-receive contrib/ccs-backup-receive /usr/local/bin/
COPY contrib/docker/web/sshd_config /etc/ssh/sshd_config
COPY contrib/docker/web/init /usr/local/bin/ccs-web-init

# Only what the gate, the backup receiver and sshd run: of openssh, sshd (and ssh-keygen, for the
# host key the first time); of git, git, its https transport and upload-pack (a file:// fetch);
# of util-linux, flock; of Python, no tests, IDLE, Tk, pip or headers, its modules compiled
# again in place of the packaged .pyc (whose source times every file's commit time changes:
# unchecked-hash .pyc don't depend on them). rrsync from rsync's own source. /bin/sh is bash
# (git runs a file:// fetch's upload-pack through it). /etc/passwd and group: links to the ones
# init writes in the mounted key folder (a mounted file replaced would stay the old one). Headers, static libraries and manuals
# dropped; every file the commit's time.
FROM toolchain AS fix
ARG SOURCE_DATE_EPOCH
COPY --from=tree / /rootfs/
RUN --mount=type=bind,source=container,target=/pin \
    tar -xzf /pin/sources/rsync-3.5.0.tar.gz -C / rsync-3.5.0/support/rrsync \
    && install -m 755 /rsync-3.5.0/support/rrsync /rootfs/usr/bin/rrsync \
    && cd /rootfs \
    && rm -rf usr/include usr/lib/pkgconfig usr/lib/*.a usr/lib/*.la usr/share/man usr/share/doc usr/share/info \
    && mv usr/libexec/git-core/git-remote-https usr/libexec/git-remote-https \
    && rm -rf usr/libexec/git-core usr/share/git-core usr/bin/git-* usr/bin/scalar \
    && mkdir -p usr/libexec/git-core usr/share/git-core/templates && mv usr/libexec/git-remote-https usr/libexec/git-core/ \
    && ln -s git-remote-https usr/libexec/git-core/git-remote-http && ln -s /usr/bin/git usr/libexec/git-core/git-upload-pack \
    && rm -rf usr/bin/ssh usr/bin/scp usr/bin/sftp usr/bin/ssh-add usr/bin/ssh-agent usr/bin/ssh-keyscan \
        usr/lib/ssh/sftp-server usr/lib/ssh/ssh-keysign usr/lib/ssh/ssh-pkcs11-helper usr/lib/ssh/ssh-sk-helper \
        etc/ssh/ssh_config usr/bin/rsync-ssl usr/bin/xxh*sum usr/bin/*zstd* usr/bin/*-config usr/bin/wcurl \
        usr/bin/bashbug usr/bin/c_rehash usr/bin/ldd usr/sbin/update-ca-certificates usr/bin/captoinfo \
        usr/bin/clear usr/bin/infocmp usr/bin/infotocap usr/bin/reset usr/bin/tabs usr/bin/tic usr/bin/toe \
        usr/bin/tput usr/bin/tset usr/bin/cjpeg usr/bin/djpeg usr/bin/jpegtran usr/bin/rdjpgcom usr/bin/wrjpgcom \
        usr/bin/tjbench usr/bin/gif* usr/bin/png-fix-itxt usr/bin/pngfix usr/bin/idle3* usr/bin/pydoc3* \
        usr/bin/2to3* usr/bin/pip* \
    && rm -f usr/bin/getfacl usr/bin/setfacl usr/bin/chacl usr/bin/getfattr usr/bin/setfattr usr/bin/attr \
    && py=usr/lib/python3.14 && rm -rf $py/test $py/idlelib $py/tkinter $py/turtledemo $py/ensurepip \
        $py/lib2to3 $py/pydoc_data $py/config-3.14* $py/site-packages/* \
    && find usr/lib/python3.14 -name __pycache__ -prune -exec rm -rf {} + \
    && PYTHONHASHSEED=0 chroot /rootfs /usr/bin/python3 -I -m compileall -q -j 1 \
        --invalidation-mode unchecked-hash /usr/lib/python3.14 > /dev/null \
    && ln -s bash usr/bin/sh && ln -sf /etc/ccs-ssh/keys/passwd etc/passwd && ln -sf /etc/ccs-ssh/keys/group etc/group \
    && chmod 755 usr/local/bin/ccs-receive usr/local/bin/ccs-backup-receive usr/local/bin/ccs-web-init && chmod 644 etc/ssh/sshd_config \
    && find . -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +

FROM scratch AS image
COPY --from=fix /rootfs/ /
ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ENTRYPOINT ["/usr/sbin/sshd", "-D", "-e"]

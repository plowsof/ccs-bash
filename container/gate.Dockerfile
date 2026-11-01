# The gate's image: the web server's side (contrib/docker/web): sshd, the gate (ccs-receive), the
# backup receiver (ccs-backup-receive) and what they run. Built as the ccs-bash image is
# (container/build.sh ccs-gate gate.Dockerfile): StageX images by digest (container/images,
# signatures checked), sources by sha256 (sources.lock), no network in the steps, every file the
# commit's time, one layer in an empty image. GNU userland, as the gate was written and tested
# for (Debian's); its checks ccs-check's (contrib/ccs-check: Go, built here), which also
# receives the push. No Python, and no C library reads an image a push brings (qrencode's
# libpng only writes the QR codes the gate compares the backend's with).

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

# ccs-check's modules (gozxing, golang.org/x/xerrors) from their pinned archives (sources.lock:
# the files Go's checksum database has for their versions), the QR reader's files only, patched
# (contrib/ccs-check/deps.sh), at /deps, where its go.mod has them
FROM toolchain AS ccs-check-deps
COPY --from=bash / /
COPY --from=ncurses / /
RUN --mount=type=bind,source=container,target=/pin --mount=type=bind,source=contrib/ccs-check,target=/c \
    bash /pin/verify.sh /pin/sources.lock /pin/sources && bash /c/deps.sh /pin/sources /deps

# ccs-check, the gate's checks in Go (contrib/ccs-check), as its build.sh builds it: StageX's Go
# alone (it has no shell: the exec form), as root (a clone made under umask 077 is its owner's
# alone: StageX's user couldn't read it), with no network, so the same bytes
FROM go AS ccs-check
USER 0
COPY --from=ccs-check-deps /deps /deps
ENV HOME=/tmp GOCACHE=/tmp/cache GOPATH=/tmp/go CGO_ENABLED=0 GOFLAGS=-mod=readonly GOPROXY=off GOTOOLCHAIN=local
RUN --mount=type=bind,source=contrib/ccs-check,target=/src ["/usr/bin/go", "-C", "/src", "build", "-trimpath", "-buildvcs=false", "-ldflags=-buildid=", "-o", "/tmp/ccs-check", "."]

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
COPY --from=coreutils / /
COPY --from=findutils / /
COPY --from=grep / /
COPY --from=sed / /
COPY --from=gawk / /
COPY --from=diffutils / /
COPY --from=tar / /
COPY --from=util-linux /usr/bin/flock /usr/bin/flock
COPY --from=acl / /
COPY --from=attr / /
COPY --from=libpng / /
COPY --from=qrencode /rootfs/ /
COPY contrib/ccs-receive contrib/ccs-backup-receive /usr/local/bin/
COPY --from=ccs-check --chown=0:0 /tmp/ccs-check /usr/local/bin/ccs-check
COPY contrib/docker/web/sshd_config /etc/ssh/sshd_config
COPY contrib/docker/web/init /usr/local/bin/ccs-web-init

# Only what the gate, the backup receiver and sshd run: of openssh, sshd (and ssh-keygen, for the
# host key the first time); of git, git, its https transport and upload-pack (a file:// fetch);
# of util-linux, flock; of rsync, rsync (ccs-check rrsync runs it). /bin/sh is bash
# (git runs a file:// fetch's upload-pack through it); /var/log, where compose.yml mounts the gate's log. /etc/passwd and group: links to the ones
# init writes in the mounted key folder (a mounted file replaced would stay the old one). Headers, static libraries and manuals
# dropped; every file the commit's time.
FROM toolchain AS fix
ARG SOURCE_DATE_EPOCH
COPY --from=tree / /rootfs/
RUN cd /rootfs \
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
        usr/bin/tput usr/bin/tset usr/bin/png-fix-itxt usr/bin/pngfix \
    && rm -f usr/bin/getfacl usr/bin/setfacl usr/bin/chacl usr/bin/getfattr usr/bin/setfattr usr/bin/attr \
    && mkdir -p var/log && ln -s bash usr/bin/sh && ln -sf /etc/ccs-ssh/keys/passwd etc/passwd && ln -sf /etc/ccs-ssh/keys/group etc/group \
    && chmod 755 usr/local/bin/ccs-receive usr/local/bin/ccs-backup-receive usr/local/bin/ccs-check usr/local/bin/ccs-web-init && chmod 644 etc/ssh/sshd_config \
    && find . -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +

FROM scratch AS image
COPY --from=fix /rootfs/ /
ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ENTRYPOINT ["/usr/sbin/sshd", "-D", "-e"]

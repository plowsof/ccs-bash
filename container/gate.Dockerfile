# The gate's image: the web server's side (contrib/docker/web): sshd, the gate (ccs-receive), the
# backup receiver (ccs-backup-receive) and what they run; and the site's front: Caddy (HTTPS, its
# certificates its own) and Tor (the onion), each its own service. Built as the ccs-bash image is
# (container/build.sh ccs-gate gate.Dockerfile): StageX images by digest (container/images,
# signatures checked), sources by sha256 (sources.lock), no network in the steps, every file the
# commit's time, one layer in an empty image. Its userland busybox, built here with only the
# applets in gate-busybox-applets (as the ccs-bash image's); its checks ccs-check's (contrib/ccs-check: Go, built here), which also
# receives the push (a tar, read in Go: no rsync), and the site it builds: jq and the vendored
# ccs-front-bash. No Python, and nothing here reads an image: a proposal's is the proposals
# repository's, a donation box's QR code the signed list's file, by its sum.

# ccs-check, the gate's checks in Go (contrib/ccs-check: Go's standard library alone, no module),
# as its build.sh builds it: StageX's Go alone (it has no shell: the exec form), as root (a clone
# made under umask 077 is its owner's alone: StageX's user couldn't read it), with no network, so
# the same bytes
FROM go AS ccs-check
USER 0
ENV HOME=/tmp GOCACHE=/tmp/cache GOPATH=/tmp/go CGO_ENABLED=0 GOFLAGS=-mod=readonly GOPROXY=off GOTOOLCHAIN=local
RUN --mount=type=bind,source=contrib/ccs-check,target=/src ["/usr/bin/go", "-C", "/src", "build", "-trimpath", "-buildvcs=false", "-ldflags=-buildid=", "-o", "/tmp/ccs-check", "."]

# Tor, from its signed source (sources.lock): a client and onion service only (no relay or
# directory authority code), with StageX's OpenSSL, zlib and libevent; no compression libraries,
# seccomp or systemd. The toolchain's cc is clang.
FROM toolchain AS tor
COPY --from=bash / /
COPY --from=ncurses / /
COPY --from=openssl / /
COPY --from=zlib / /
COPY --from=libevent / /
RUN --mount=type=bind,source=container,target=/pin \
    bash /pin/verify.sh /pin/sources.lock /pin/sources \
    && tar -xzf /pin/sources/tor-0.4.9.15.tar.gz -C / \
    && cd /tor-0.4.9.15 \
    && ./configure --prefix=/usr --sysconfdir=/etc --localstatedir=/var CC=cc \
        --disable-module-relay --disable-module-dirauth --disable-unittests --disable-asciidoc \
        --disable-manpage --disable-html-manual --disable-lzma --disable-zstd --disable-seccomp \
        --disable-systemd --disable-libscrypt > /dev/null \
    && make -j"$(nproc)" > /dev/null \
    && install -D -m 755 src/app/tor /rootfs/usr/bin/tor

# busybox with only the applets in gate-busybox-applets (and their options), as the ccs-bash
# image builds its own (Dockerfile)
FROM toolchain AS busybox
COPY --from=bash / /
COPY --from=ncurses / /
ENV KCONFIG_NOTIMESTAMP=1
RUN --mount=type=bind,source=container,target=/pin \
    bash /pin/verify.sh /pin/sources.lock /pin/sources \
    && tar -xjf /pin/sources/busybox-1.38.0.tar.bz2 -C / \
    && cd /busybox-1.38.0 \
    && make HOSTCC=cc CC=cc allnoconfig > /dev/null \
    && for applet in $(grep -v -e '^#' -e '^CONFIG_' /pin/gate-busybox-applets); do \
        config=CONFIG_$(echo "$applet" | tr 'a-z-' 'A-Z_'); \
        grep -q "^# $config is not set$" .config || { echo "no applet $applet" >&2; exit 1; }; \
        sed -i "s/^# $config is not set$/$config=y/" .config; \
        sed -i "s/^# \(CONFIG_FEATURE_${config#CONFIG_}_[A-Z0-9_]*\) is not set$/\1=y/" .config; \
    done \
    && for config in CONFIG_LONG_OPTS $(grep '^CONFIG_' /pin/gate-busybox-applets); do \
        grep -q "^# $config is not set$" .config || { echo "no option $config" >&2; exit 1; }; \
        sed -i "s/^# $config is not set$/$config=y/" .config; \
    done \
    && yes "" | make HOSTCC=cc CC=cc oldconfig > /dev/null \
    && for config in $(grep '^CONFIG_' /pin/gate-busybox-applets); do grep -qx "$config=y" .config || { echo "$config off" >&2; exit 1; }; done \
    && make HOSTCC=cc CC=cc > /dev/null \
    && install -D -m 755 busybox /rootfs/usr/bin/busybox \
    && for applet in $(grep -v -e '^#' -e '^CONFIG_' /pin/gate-busybox-applets); do \
        ln -s busybox "/rootfs/usr/bin/$applet"; \
        ! "/rootfs/usr/bin/$applet" --help 2>&1 | grep -q "applet not found" || { echo "$applet not built" >&2; exit 1; }; \
    done

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
COPY --from=git / /
COPY --from=jq / /
COPY --from=openssh / /
COPY --from=caddy /usr/bin/caddy /usr/bin/caddy
COPY --from=libevent / /
COPY --from=tor /rootfs/ /
COPY contrib/ccs-receive contrib/ccs-backup-receive /usr/local/bin/
# the site, built here (contrib/gate-build): ccs-bash's steps for its JSON (lib/site-data.sh and
# what it uses), and the vendored ccs-front-bash release (vendor/)
COPY lib/common.sh lib/proposals.sh lib/images.sh lib/site-data.sh lib/site.jq lib/frontmatter.awk /usr/local/lib/ccs-gate/lib/
COPY vendor/ccs-front-bash /usr/local/lib/ccs-gate/vendor/ccs-front-bash
COPY contrib/gate-build /usr/local/lib/ccs-gate/contrib/gate-build
COPY --from=ccs-check --chown=0:0 /tmp/ccs-check /usr/local/bin/ccs-check
COPY contrib/docker/web/sshd_config /etc/ssh/sshd_config
COPY contrib/docker/web/init /usr/local/bin/ccs-web-init
COPY contrib/docker/web/Caddyfile /etc/caddy/Caddyfile
COPY contrib/docker/web/torrc /etc/tor/torrc

# Only what the gate, the backup receiver and sshd run: of openssh, sshd (and ssh-keygen, for the
# host key the first time); of git, git, its https transport and upload-pack (a file:// fetch);
# of ncurses, the library bash needs. /bin/sh is bash
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
        etc/ssh/ssh_config usr/bin/*zstd* usr/bin/*-config usr/bin/wcurl \
        usr/bin/bashbug usr/bin/c_rehash usr/bin/ldd usr/sbin/update-ca-certificates usr/bin/captoinfo \
        usr/bin/clear usr/bin/infocmp usr/bin/infotocap usr/bin/reset usr/bin/tabs usr/bin/tic usr/bin/toe \
        usr/bin/tput usr/bin/tset usr/bin/event_rpcgen.py \
    && rm -f usr/lib/libform*.so* usr/lib/libmenu*.so* usr/lib/libpanel*.so* usr/lib/libncurses++*.so* \
    && ln -s ../lib/ccs-gate/contrib/gate-build usr/local/bin/ccs-gate-build \
    && find usr/local/lib/ccs-gate -type d -exec chmod 755 {} + && find usr/local/lib/ccs-gate -type f -exec chmod 644 {} + \
    && chmod 755 usr/local/lib/ccs-gate/contrib/gate-build \
    && mkdir -p var/log && ln -s bash usr/bin/sh && ln -sf /etc/ccs-ssh/keys/passwd etc/passwd && ln -sf /etc/ccs-ssh/keys/group etc/group \
    && chmod 755 usr/local/bin/ccs-receive usr/local/bin/ccs-backup-receive usr/local/bin/ccs-check usr/local/bin/ccs-web-init && chmod 644 etc/ssh/sshd_config etc/caddy/Caddyfile etc/tor/torrc \
    && find . -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +

FROM scratch AS image
COPY --from=fix /rootfs/ /
ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ENTRYPOINT ["/usr/sbin/sshd", "-D", "-e"]

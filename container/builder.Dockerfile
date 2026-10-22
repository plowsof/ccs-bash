# The builder: BuildKit from StageX, which build.sh runs as a buildx builder of its own (the
# docker-container driver) to build the ccs-bash image, instead of the BuildKit that comes
# with the host's Docker. So the program doing the build is pinned and signed like the rest,
# and a Docker upgrade on the host can't change how the image is put together.
# Only COPY: built by the host's Docker, but with nothing run in it.
FROM scratch
COPY --from=filesystem / /
COPY --from=musl / /
COPY --from=ca-certificates / /
COPY --from=libseccomp / /
COPY --from=runc / /
COPY --from=buildkit / /
# buildkitd needs root in its container (the docker-container driver runs it privileged)
USER 0:0
ENTRYPOINT ["/usr/bin/buildkitd"]

# Slim Cube runtime: server + oracle-driver + mysql-driver only.
# Build once, publish to Docker Hub, then FROM it or docker run it.
#
# The build stage needs npm, so it runs on the Debian "slim" Node image.
# The runtime stage is distroless: it ships glibc and node and nothing else.
# That is what keeps the CRITICAL count at zero - see README "Why distroless".

ARG BASE_IMAGE=node:24.21.0-trixie-slim@sha256:db3ae80f5d8df06e04dabdf7b44cbf008d32de168205fa0294444aabbc08c590
ARG RUNTIME_IMAGE=gcr.io/distroless/nodejs24-debian13:nonroot@sha256:bb6b03d81066993293a10feda7250e8e1cc034035fe9b61cfceededa7c8bf04d

# ---------- build stage ----------
FROM ${BASE_IMAGE} AS build
WORKDIR /cube

ARG CUBE_VERSION=1.7.40
ARG NATIVE_SHA256=b3b4a7475331d9e96709d66dcd2bfe52c3a8093da722986b2a852c3600b68452

COPY package.json package-lock.json ./
COPY vendor/native-${CUBE_VERSION}-linux-x64-glibc-fallback.tar.gz /tmp/native.tgz

# Install scripts are skipped on purpose:
#  - @cubejs-backend/native: binary comes from the vendored, checksum-verified tarball
#  - @cubejs-backend/cubestore: embedded Cube Store is dev-mode only
#  - oracledb: install script is only a sanity check (prebuilt binary ships in the package)
# /cube/conf is created here because the runtime stage has no shell to mkdir with.
RUN npm ci --omit=dev --ignore-scripts --no-audit --no-fund \
 && echo "${NATIVE_SHA256}  /tmp/native.tgz" > /tmp/native.sha256 \
 && sha256sum -c /tmp/native.sha256 \
 && tar -xzf /tmp/native.tgz -C node_modules/@cubejs-backend/native \
 && test -f node_modules/@cubejs-backend/native/native/index.node \
 && find node_modules -name '*.map' -type f -delete \
 && rm -f package.json package-lock.json \
 && mkdir -p /cube/conf

# ---------- runtime stage ----------
FROM ${RUNTIME_IMAGE}

ARG CUBE_VERSION=1.7.40
LABEL org.opencontainers.image.title="cube-server" \
      org.opencontainers.image.version="${CUBE_VERSION}"

# Same layout as the official cubejs/cube image: config and model live in /cube/conf
ENV NODE_ENV=production \
    NODE_PATH=/cube/conf/node_modules:/cube/node_modules

# Distroless ships no package manager and no shell, so there is nothing to strip
# here: the advisories against npm's bundled dependencies are absent by default.
COPY --from=build --chown=65532:65532 /cube /cube

# The base image already runs as nonroot (uid 65532) and its ENTRYPOINT is node,
# so CMD is the server entry script rather than the cubejs-server shim.
WORKDIR /cube/conf
EXPOSE 4000
CMD ["/cube/node_modules/@cubejs-backend/server/bin/server"]

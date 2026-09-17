# cube-server - slim Cube runtime image

A minimal Cube runtime image built from npm, pinned to Cube **1.7.40**, carrying only
the packages we actually use. It is a drop-in replacement for `cubejs/cube` for our
deployments, and it passes the corporate Harbor scan with **0 CRITICAL** findings.

Published as `docker.io/sychen6192/cubejs`.

```
docker pull docker.io/sychen6192/cubejs:v1.7.40
```

## Why this image exists

The official `cubejs/cube:v1.7.37` image is blocked by our Harbor scan on three CRITICAL
findings. All three come from drivers we do not use, pulled in by the way the official
image is assembled - so changing the official image tag does not help:

| CVE | Package | Why it is in the official image |
| --- | --- | --- |
| CVE-2022-41853 | `hsqldb.jar` 2.3.2 | Bundled in `@cubejs-backend/jdbc`, via `databricks-jdbc-driver` |
| CVE-2019-10744 | `lodash` 3.10.1 | Nested under `jshs2`, via `hive-driver` |
| CVE-2026-4800 | `lodash` 4.17.23 | Pinned by the Cube monorepo `yarn.lock` |

This image installs only four packages from the public npm registry:

- `@cubejs-backend/server` 1.7.40
- `@cubejs-backend/oracle-driver` 1.7.40
- `@cubejs-backend/mysql-driver` 1.7.40
- `oracledb` 6.10.0

A fresh npm resolution (rather than the monorepo lockfile) gives `lodash` **4.18.1**, no
`jshs2`, no `hive-driver`, no `databricks-jdbc-driver` and therefore no JAR files at all.
All three blocked CVEs are absent, and `scripts/scan.sh` fails the build if any of them
ever reappears.

## Why distroless

The runtime stage is `gcr.io/distroless/nodejs24-debian13:nonroot`, not the Debian
"slim" Node image the build stage uses.

`node:24.21.0-trixie-slim` is the newest Node 24 trixie tag available, and it currently
carries three CRITICAL findings in `perl-base` 5.40.1-6 (CVE-2026-13221, CVE-2026-42496,
CVE-2026-8376). Debian has fixed them in 5.40.1-6+deb13u1, but the Node image has not
been rebuilt against that update yet, so no newer tag clears them.

Distroless has no `perl`, no shell and no package manager, so those findings - and the
advisories against npm's bundled dependencies - are absent by construction rather than
patched away. It also makes the image smaller: the runtime base is 214 MB instead of 347 MB, and the
finished image is 584 MB.

Two practical consequences:

- **No shell.** `docker exec <container> sh` does not work, and a derived image can use
  `COPY` but not `RUN`. Every check in `scripts/smoke.sh` is driven through `node`,
  which is the image ENTRYPOINT.
- **The runtime user is uid 65532** (`nonroot`), not uid 1000 (`node`). Mounted files
  and any writable volume must be readable/writable by 65532.

The `/cube/conf` layout is unchanged, so config and model paths behave exactly as they
do with `cubejs/cube`.

## Running it

Config and data model live in `/cube/conf`, the same as the official image.

```
docker run --rm -p 4000:4000 \
  --env-file ./cube.env \
  -v "$PWD/cube.js:/cube/conf/cube.js:ro" \
  -v "$PWD/model:/cube/conf/model:ro" \
  docker.io/sychen6192/cubejs:v1.7.40
```

Or bake the config in. Note that `RUN` is unavailable in a derived image, because the
base has no shell - copy files in and nothing else:

```dockerfile
FROM docker.io/sychen6192/cubejs:v1.7.40
COPY --chown=65532:65532 cube.js /cube/conf/cube.js
COPY --chown=65532:65532 model/ /cube/conf/model/
```

The API listens on port 4000 and serves `/livez` and `/readyz` for health checks.

On startup the server logs two warnings that are expected with this image:

- `Unable to detect what host library is used as libc, continue with gnu` - distroless
  has no `ldd` for the native loader to probe, so it falls back to glibc, which is the
  variant that is vendored. The native module loads fine; the smoke test checks this.
- `Cube Store is not found` - the embedded Cube Store is dev-mode only and is not
  shipped. In production point `CUBEJS_CUBESTORE_HOST` at your Cube Store deployment,
  exactly as with the official image.

## Tags

| Tag | Meaning |
| --- | --- |
| `v1.7.40` | The Cube version. What deployments and corporate CI should pin. |
| `v1.7.40-<short sha>` | Immutable per-commit build, for rollback. |
| `latest` | Most recent successful build of the default branch. |

Version tags carry a `v` prefix like the official `cubejs/cube` tags; the workflow
derives them from `CUBE_VERSION`, so an upgrade changes one value.

Tags are pushed only from the default branch. Pull request builds are built, scanned and
smoke-tested but never pushed.

## Upgrading Cube

The vendored native binary is version-specific, so all of these move together:

1. Bump the three `@cubejs-backend/*` versions in `package.json` to the new version.
   They must all match - mixing versions is not supported.
2. Regenerate the lockfile:
   `npm install --package-lock-only --ignore-scripts`
3. Vendor the matching native tarball as
   `vendor/native-<version>-linux-x64-glibc-fallback.tar.gz`.
4. Update `NATIVE_SHA256` in the `Dockerfile` to the sha256 of that tarball
   (`sha256sum vendor/native-<version>-linux-x64-glibc-fallback.tar.gz`).
5. Update `CUBE_VERSION` in the `Dockerfile` and in `.github/workflows/publish.yml`.
6. Re-pin `BASE_IMAGE` and `RUNTIME_IMAGE` to current digests while you are there.

The build verifies the checksum before extracting and fails if it does not match, so a
forgotten step 4 breaks the build rather than shipping a mismatched binary.

## Verifying

```
scripts/scan.sh docker.io/sychen6192/cubejs:v1.7.40   # 0 CRITICAL, blocked CVEs absent
scripts/smoke.sh docker.io/sychen6192/cubejs:v1.7.40  # prints SMOKE PASS
```

`scripts/scan.sh` fails the build on any CRITICAL finding and on any of the three blocked
CVEs specifically, so a regression cannot be published.

## Known findings

Trivy 0.74.0, `--scanners vuln`: **0 CRITICAL**, 2 HIGH, 15 MEDIUM, 8 LOW.

Both remaining HIGH findings are the same package, and both are accepted:

| CVE | Package | Fix | Justification |
| --- | --- | --- | --- |
| CVE-2026-56876 | `extract-zip` 2.0.1 | none upstream | Only reachable via `downloadAndExtractFile()` in `@cubejs-backend/shared`, whose callers are the native postinstall (disabled at build time, binary vendored and checksum-verified) and the embedded Cube Store downloader (dev mode only). Not reachable at runtime. |
| CVE-2026-19693 | `extract-zip` 2.0.1 | none upstream | Same reachability analysis as above. |

There are no OS-package findings at HIGH or CRITICAL: the distroless runtime contributes
zero of either.

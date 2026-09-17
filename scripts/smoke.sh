#!/usr/bin/env bash
# Smoke test: the image runs as the nonroot user, has no package managers, carries the
# native module, and answers /livez without any database being reachable.
#
# The runtime stage is distroless: there is no shell and no coreutils in the image, so
# every in-container check is driven through node, which is the image ENTRYPOINT.
# Usage: scripts/smoke.sh <image>
set -euo pipefail
IMAGE="${1:?image}"
CUBE_VERSION="${CUBE_VERSION:-1.7.40}"
SERVER_BIN="/cube/node_modules/@cubejs-backend/server/bin/server"

docker run --rm "${IMAGE}" "${SERVER_BIN}" --version | grep -q "@cubejs-backend/server/${CUBE_VERSION} "
[ "$(docker run --rm "${IMAGE}" -e 'console.log(process.getuid())')" = "65532" ]
docker run --rm "${IMAGE}" -e '
const fs = require("fs");
const names = ["npm", "npx", "yarn", "yarnpkg", "corepack"];
const dirs = (process.env.PATH || "").split(":").concat(["/usr/local/bin", "/usr/bin", "/bin", "/nodejs/bin"]);
const found = [];
for (const d of dirs) { for (const n of names) { try { fs.accessSync(d + "/" + n); found.push(d + "/" + n); } catch (e) {} } }
if (found.length) { console.error("package manager present: " + found.join(", ")); process.exit(1); }
' >/dev/null
docker run --rm "${IMAGE}" -e 'require("fs").accessSync("/cube/node_modules/@cubejs-backend/native/native/index.node")'

cid=$(docker run -d -p 4000:4000 \
  -e CUBEJS_DB_TYPE=mysql -e CUBEJS_DB_HOST=127.0.0.1 -e CUBEJS_DB_PORT=9 \
  -e CUBEJS_API_SECRET=smoke -e CUBEJS_CACHE_AND_QUEUE_DRIVER=memory "${IMAGE}")
trap 'docker logs "${cid}" 2>&1 | tail -20; docker rm -f "${cid}" >/dev/null' EXIT
for _ in $(seq 1 30); do
  if curl -sf localhost:4000/livez >/dev/null 2>&1; then break; fi
  sleep 2
done
curl -sf localhost:4000/livez | grep -q HEALTH
docker logs "${cid}" 2>&1 | grep -q "Cube API server (${CUBE_VERSION}) is listening"
echo "SMOKE PASS"

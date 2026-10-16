#!/bin/sh
# Runs scripts/linux-smoke.mjs against an UNPACKED Linux bundle inside the existing local
# luma-linux-qa:node24 Docker image (docker build -t luma-linux-qa:node24 qa/linux). Isolated: no network,
# read-only app and scripts, tmpfs scratch. A read-only root filesystem and no-new-privileges stalled
# xvfb-run in testing, so they are intentionally not set.
#
#   scripts/linux-container-smoke.sh release-linux/linux-arm64-unpacked luma     # arm64 host/runtime
#
# CONTAINER-ONLY CONCESSIONS (not desktop advice): seccomp=unconfined lets Chromium create the
# user-namespace sandbox, and --disable-setuid-sandbox selects it because the bind-mounted
# chrome-sandbox is not root-owned 4755. --no-sandbox is never used.
# Runs on the Docker daemon's own architecture; an x64 bundle on an arm64 daemon will not execute.
set -eu
bundle=${1:?usage: $0 <unpacked-bundle-dir> [executable-name]}
exe=${2:-luma}
here=$(cd "$(dirname "$0")" && pwd)
bundle=$(cd "$bundle" && pwd)
exec docker run --rm --name "luma-linux-smoke-$$" \
  --network none --tmpfs /tmp:rw,size=512m \
  --security-opt seccomp=unconfined --user node \
  -v "$bundle:/app:ro" -v "$here:/smoke:ro" \
  luma-linux-qa:node24 \
  timeout 60s xvfb-run -a node /smoke/linux-smoke.mjs --app "/app/$exe" -- --disable-setuid-sandbox

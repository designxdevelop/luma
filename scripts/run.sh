#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ ! -x dist/Luma.app/Contents/MacOS/Luma ]]; then ./scripts/build-app.sh; fi
open dist/Luma.app --args "$@"

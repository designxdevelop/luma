#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Native SwiftPM avoids this toolchain's unsigned XCTest bundle loader.
# The loopback integration test needs permission to bind localhost.
swift test --disable-sandbox --build-system native

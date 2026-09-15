#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
SIDEBRIEF_DEVELOPER_DIR="$(xcode-select -p)"
SIDEBRIEF_TEST_FLAGS=()
if [[ "$SIDEBRIEF_DEVELOPER_DIR" == */CommandLineTools ]] && [[ -d "$SIDEBRIEF_DEVELOPER_DIR/Library/Developer/Frameworks/Testing.framework" ]]; then
  SIDEBRIEF_FRAMEWORKS="$SIDEBRIEF_DEVELOPER_DIR/Library/Developer/Frameworks"
  SIDEBRIEF_TEST_FLAGS=(-Xswiftc -F -Xswiftc "$SIDEBRIEF_FRAMEWORKS" -Xlinker -F -Xlinker "$SIDEBRIEF_FRAMEWORKS" -Xlinker -rpath -Xlinker "$SIDEBRIEF_FRAMEWORKS" -Xlinker -rpath -Xlinker "$SIDEBRIEF_DEVELOPER_DIR/Library/Developer/usr/lib")
fi
swift test --disable-sandbox --disable-xctest --enable-swift-testing --scratch-path .build --cache-path .build/cache "${SIDEBRIEF_TEST_FLAGS[@]}" "$@"

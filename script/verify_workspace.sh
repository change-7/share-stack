#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-${TMPDIR:-/private/tmp}/sharestack-clang-cache}"
export SWIFT_MODULECACHE_PATH="${SWIFT_MODULECACHE_PATH:-${TMPDIR:-/private/tmp}/sharestack-swift-cache}"
xcrun swiftc -parse-as-library "$ROOT_DIR/macos/ShareStackMac/Sources/ShareStackMac/WorkspaceStore.swift" "$ROOT_DIR/macos/ShareStackMac/Tests/WorkspaceRegression.swift" -o "${TMPDIR:-/private/tmp}/sharestack-workspace-test"
"${TMPDIR:-/private/tmp}/sharestack-workspace-test"

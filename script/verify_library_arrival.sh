#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_DIR="$ROOT_DIR/macos/ShareStackMac/Sources/ShareStackMac"
OUTPUT="${TMPDIR:-/private/tmp}/share-stack-arrival-regression"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-${TMPDIR:-/private/tmp}/sharestack-clang-cache}"
export SWIFT_MODULECACHE_PATH="${SWIFT_MODULECACHE_PATH:-${TMPDIR:-/private/tmp}/sharestack-swift-cache}"
xcrun swiftc -parse-as-library \
  "$SOURCE_DIR/NetworkIdentity.swift" "$SOURCE_DIR/TLSIdentity.swift" \
  "$SOURCE_DIR/ShareHandoff.swift" "$SOURCE_DIR/TransferStore.swift" "$SOURCE_DIR/WorkspaceStore.swift" \
  "$SOURCE_DIR/TransferJobs.swift" "$SOURCE_DIR/TransferHTTPServer.swift" \
  "$ROOT_DIR/macos/ShareStackMac/Tests/LibraryArrivalRegression.swift" -o "$OUTPUT"
"$OUTPUT"

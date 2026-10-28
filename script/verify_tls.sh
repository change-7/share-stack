#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_DIR="$ROOT_DIR/macos/ShareStackMac/Sources/ShareStackMac"
TEST_FILE="$ROOT_DIR/macos/ShareStackMac/Tests/TLSIdentityRegression.swift"
OUTPUT="${TMPDIR:-/private/tmp}/share-stack-tls-regression"

xcrun swiftc -parse-as-library \
  "$SOURCE_DIR/NetworkIdentity.swift" \
  "$SOURCE_DIR/TLSIdentity.swift" \
  "$TEST_FILE" \
  -o "$OUTPUT"
"$OUTPUT"

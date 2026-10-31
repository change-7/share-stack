#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_JAVA_HOME="${JAVA_HOME:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}"
OUTPUT="$(mktemp -d "${TMPDIR:-/private/tmp}/sharestack-ai-java.XXXXXX")"
trap 'rm -rf "$OUTPUT"' EXIT
"$TEST_JAVA_HOME/bin/javac" -d "$OUTPUT" \
  "$ROOT_DIR/app/src/main/java/com/pdg/sharestack/AIReadIntent.java" \
  "$ROOT_DIR/app/src/test/java/com/pdg/sharestack/AIReadIntentRegression.java"
"$TEST_JAVA_HOME/bin/java" -ea -cp "$OUTPUT" com.pdg.sharestack.AIReadIntentRegression

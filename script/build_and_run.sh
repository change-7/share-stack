#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DIR="${TMPDIR:-/private/tmp}/share-stack-macos-derived"
APP_BUNDLE="$ROOT_DIR/ShareStackMac.app"
MODE="${1:-run}"
CONFIGURATION="Release"
SIGNING_ARGS=(CODE_SIGNING_ALLOWED=NO)
if [[ -n "${SHARESTACK_CODE_SIGN_IDENTITY:-}" ]]; then
  SIGNING_ARGS=(CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY="$SHARESTACK_CODE_SIGN_IDENTITY" CODE_SIGN_STYLE=Automatic)
  if [[ -n "${SHARESTACK_DEVELOPMENT_TEAM:-}" ]]; then
    SIGNING_ARGS+=(DEVELOPMENT_TEAM="$SHARESTACK_DEVELOPMENT_TEAM")
  fi
fi
if [[ "$MODE" == "--debug" ]]; then CONFIGURATION="Debug"; fi

case "$MODE" in
  run|--verify|--debug|--logs|--telemetry) ;;
  *) echo "usage: $0 [--verify|--debug|--logs|--telemetry]" >&2; exit 2 ;;
esac

/usr/bin/pkill -TERM -x ShareStackMac || true
if [[ -n "${SHARESTACK_DEVELOPMENT_TEAM:-}" ]]; then
  /usr/bin/xcodebuild -quiet \
    -project "$ROOT_DIR/macos/ShareStackMac/ShareStackMac.xcodeproj" \
    -scheme ShareStackMac -configuration "$CONFIGURATION" \
    -destination "platform=macOS,arch=$(uname -m)" \
    -derivedDataPath "$DERIVED_DIR" -allowProvisioningUpdates "${SIGNING_ARGS[@]}" build
else
  /usr/bin/xcodebuild -quiet \
    -project "$ROOT_DIR/macos/ShareStackMac/ShareStackMac.xcodeproj" \
    -scheme ShareStackMac -configuration "$CONFIGURATION" \
    -destination "platform=macOS,arch=$(uname -m)" \
    -derivedDataPath "$DERIVED_DIR" "${SIGNING_ARGS[@]}" build
fi
/bin/mkdir -p "$APP_BUNDLE"
/usr/bin/rsync -a --delete "$DERIVED_DIR/Build/Products/$CONFIGURATION/ShareStackMac.app/" "$APP_BUNDLE/"

if [[ "$MODE" == "--debug" ]]; then
  exec /usr/bin/lldb -- "$APP_BUNDLE/Contents/MacOS/ShareStackMac"
fi

/usr/bin/open "$APP_BUNDLE"
case "$MODE" in
  --verify)
    for attempt in {1..30}; do
      if /usr/bin/pgrep -x ShareStackMac >/dev/null; then exit 0; fi
      /bin/sleep 0.1
    done
    echo "Share Stack did not start" >&2
    exit 1
    ;;
  --logs|--telemetry)
    exec /usr/bin/log stream --style compact --info --predicate 'process == "ShareStackMac"'
    ;;
esac

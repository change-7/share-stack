#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DIR="${TMPDIR:-/private/tmp}/share-stack-macos-derived"
APP_BUNDLE="$ROOT_DIR/ShareStackMac.app"
MODE="${1:-run}"
CONFIGURATION="Release"
SIGNING_IDENTITY="${SHARESTACK_CODE_SIGN_IDENTITY:-}"
if [[ -z "$SIGNING_IDENTITY" && -z "${SHARESTACK_DEVELOPMENT_TEAM:-}" && -d "$APP_BUNDLE" ]]; then
  CERTIFICATE_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/private/tmp}/sharestack-signing.XXXXXX")"
  trap '/bin/rm -rf "$CERTIFICATE_DIR"' EXIT
  /usr/bin/codesign -d --extract-certificates="$CERTIFICATE_DIR/certificate" "$APP_BUNDLE" >/dev/null 2>&1 || true
  if [[ -f "$CERTIFICATE_DIR/certificate0" ]]; then
    SIGNING_IDENTITY="$(/usr/bin/shasum -a 1 "$CERTIFICATE_DIR/certificate0" | /usr/bin/awk '{print $1}')"
  elif [[ -f "$APP_BUNDLE/Contents/_CodeSignature/CodeResources" ]]; then
    echo "Cannot reuse the app signing certificate. Set SHARESTACK_CODE_SIGN_IDENTITY to the existing certificate before rebuilding." >&2
    exit 1
  fi
fi
SIGNING_ARGS=(CODE_SIGNING_ALLOWED=NO)
if [[ -n "${SHARESTACK_DEVELOPMENT_TEAM:-}" ]]; then
  SIGNING_ARGS=(CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY="${SIGNING_IDENTITY:-Apple Development}" CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM="$SHARESTACK_DEVELOPMENT_TEAM")
fi
if [[ "$MODE" == "--debug" ]]; then CONFIGURATION="Debug"; fi

case "$MODE" in
  run|--build-only|--verify|--debug|--logs|--telemetry) ;;
  *) echo "usage: $0 [--build-only|--verify|--debug|--logs|--telemetry]" >&2; exit 2 ;;
esac

if [[ "$MODE" != "--build-only" ]]; then
  /usr/bin/pkill -TERM -x ShareStackMac || true
fi
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
BUILT_APP="$DERIVED_DIR/Build/Products/$CONFIGURATION/ShareStackMac.app"
if [[ -n "$SIGNING_IDENTITY" || -n "${SHARESTACK_DEVELOPMENT_TEAM:-}" ]]; then
  if [[ -z "${SHARESTACK_DEVELOPMENT_TEAM:-}" ]]; then
    /usr/bin/codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none \
      --entitlements "$ROOT_DIR/macos/ShareStackMac/ShareStackShareExtension/ShareStackShareExtension.entitlements" \
      "$BUILT_APP/Contents/PlugIns/ShareStackShareExtension.appex"
    /usr/bin/codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none \
      --entitlements "$ROOT_DIR/macos/ShareStackMac/ShareStackMac.entitlements" "$BUILT_APP"
  fi
  /usr/bin/codesign --verify --deep --strict "$BUILT_APP"
elif [[ -z "${SHARESTACK_DEVELOPMENT_TEAM:-}" ]]; then
  echo "Warning: No signing identity selected; Keychain access may require approval after each rebuild." >&2
fi
/bin/mkdir -p "$APP_BUNDLE"
/usr/bin/rsync -a --delete "$BUILT_APP/" "$APP_BUNDLE/"
if [[ -n "$SIGNING_IDENTITY" || -n "${SHARESTACK_DEVELOPMENT_TEAM:-}" ]]; then
  /usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"
fi

if [[ "$MODE" == "--build-only" ]]; then exit 0; fi

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

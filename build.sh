#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
BUILD_ROOT="${AI_ACCESS_BUILD_ROOT:-$ROOT/build}"
TARGET_ARCH="${AI_ACCESS_TARGET_ARCH:-native}"
PRODUCT_VERSION=$(
  /usr/libexec/PlistBuddy \
    -c "Print :CFBundleShortVersionString" \
    "$ROOT/Info.plist"
)
PRODUCT_BUILD=$(
  /usr/libexec/PlistBuddy \
    -c "Print :CFBundleVersion" \
    "$ROOT/Info.plist"
)
TEMP_PACKAGE="${AI_ACCESS_TEMP_PACKAGE:-0}"
EXPECTED_LOCAL_BUILD="178"
if [[ "$TEMP_PACKAGE" == "1" ]]; then
  EXPECTED_LOCAL_BUILD="${AI_ACCESS_TEMP_PACKAGE_BUILD:-}"
  if [[ -z "$EXPECTED_LOCAL_BUILD" || "$EXPECTED_LOCAL_BUILD" != <-> ]]; then
    echo "temporary package requires numeric AI_ACCESS_TEMP_PACKAGE_BUILD" >&2
    exit 1
  fi
elif [[ "$TEMP_PACKAGE" != "0" ]]; then
  echo "AI_ACCESS_TEMP_PACKAGE must be 0 or 1" >&2
  exit 1
fi
MINIMUM_MACOS=$(
  /usr/libexec/PlistBuddy \
    -c "Print :LSMinimumSystemVersion" \
    "$ROOT/Info.plist"
)
FINAL_APP="$BUILD_ROOT/AI接入助手.app"
APP_ARCHIVE="$BUILD_ROOT/旧版归档"
STAMP="$(date +%Y%m%d-%H%M%S)-$$"
APP="$BUILD_ROOT/.AI接入助手-${TARGET_ARCH}-candidate-$$.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
HELPERS="$CONTENTS/Helpers"
MODULE_CACHE="$BUILD_ROOT/module-cache-$TARGET_ARCH"
TARGET_ARGS=()
BUILD_STAGE_FILE="${AI_ACCESS_BUILD_STAGE_FILE:-}"

record_build_stage() {
  if [[ -n "$BUILD_STAGE_FILE" ]]; then
    mkdir -p "${BUILD_STAGE_FILE:h}"
    print -r -- "$1" >"$BUILD_STAGE_FILE"
    print -r -- "PUBLIC_SOURCE_BUILD_STAGE=$1"
  fi
}

record_build_stage preflight

cleanup() {
  if [[ -e "$APP" ]]; then
    mkdir -p "$APP_ARCHIVE"
    mv \
      "$APP" \
      "$APP_ARCHIVE/失败构建-${TARGET_ARCH}-$STAMP.app"
  fi
}
trap cleanup EXIT

if [[ "$PRODUCT_VERSION" != "0.12.0" || "$PRODUCT_BUILD" != "$EXPECTED_LOCAL_BUILD" ]]; then
  echo "0.12.0 local arm64 test build requires Info.plist version 0.12.0 ($EXPECTED_LOCAL_BUILD)" >&2
  exit 1
fi
if ! awk '
  $0 == "version = \"0.11.0\"" { found = 1 }
  END { exit found ? 0 : 1 }
' "$ROOT/SessionCore/Cargo.toml"; then
  echo "0.12.0 must embed the verified SessionCore component version 0.11.0" >&2
  exit 1
fi

case "$TARGET_ARCH" in
  native)
    ;;
  arm64|x86_64)
    TARGET_ARGS=(
      -target
      "${TARGET_ARCH}-apple-macosx${MINIMUM_MACOS}"
    )
    ;;
  *)
    echo "unsupported build architecture: $TARGET_ARCH" >&2
    exit 1
    ;;
esac

record_build_stage assemble_app
mkdir -p "$MACOS" "$RESOURCES" "$HELPERS" "$MODULE_CACHE"
cp "$ROOT/Info.plist" "$CONTENTS/Info.plist"
cp "$ROOT/Assets/AppIcon-v2.icns" "$RESOURCES/AppIcon.icns"
cp "$ROOT/LICENSE" "$RESOURCES/LICENSE"
cp "$ROOT/PRIVACY.md" "$RESOURCES/PRIVACY.md"
cp "$ROOT/SOURCE-CODE.md" "$RESOURCES/SOURCE-CODE.md"
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$RESOURCES/THIRD_PARTY_NOTICES.md"
cp "$ROOT/Configuration/TrustedUpdatePublicKeys.json" "$RESOURCES/TrustedUpdatePublicKeys.json"
cp \
  "$ROOT/SessionCore/THIRD_PARTY_NOTICES.md" \
  "$RESOURCES/SESSIONCORE-THIRD-PARTY-NOTICES.md"

record_build_stage rust_session_core
SESSION_CORE_BINARY=$(
  AI_ACCESS_TARGET_ARCH="$TARGET_ARCH" \
    "$ROOT/Scripts/build-session-core.sh"
)
cp "$SESSION_CORE_BINARY" "$HELPERS/ai-access-session-core"
chmod 0755 "$HELPERS/ai-access-session-core"
[[ ! -e "$HELPERS/ai-access-token-helper" ]]

SESSION_CORE_ARCHS=$(lipo -archs "$HELPERS/ai-access-session-core")
case "$TARGET_ARCH" in
  arm64)
    [[ "$SESSION_CORE_ARCHS" == "arm64" ]]
    ;;
  x86_64)
    [[ "$SESSION_CORE_ARCHS" == "x86_64" ]]
    ;;
esac

source "$ROOT/Scripts/swift-source-manifest.sh"
ai_access_load_swift_sources "$ROOT" "build.sh"

record_build_stage swift_compile
swiftc \
  -parse-as-library \
  -O \
  "${TARGET_ARGS[@]}" \
  -module-cache-path "$MODULE_CACHE" \
  -framework SwiftUI \
  -framework AppKit \
  -framework Vision \
  -framework UniformTypeIdentifiers \
  -framework Security \
  "${AI_ACCESS_SWIFT_SOURCES[@]}" \
  -lsqlite3 \
  -o "$MACOS/ConfigAdvisor"

record_build_stage codesign
codesign \
  --force \
  --sign - \
  --identifier io.github.liewlf.aiaccessassistant.session-core \
  "$HELPERS/ai-access-session-core"

codesign \
  --force \
  --sign - \
  --requirements "$ROOT/ConfigAdvisor.requirements" \
  "$APP"

[[ ! -e "$HELPERS/ai-access-token-helper" ]]
codesign --verify --strict "$HELPERS/ai-access-session-core"
codesign --verify --deep --strict "$APP"

record_build_stage finalize_app
if [[ -e "$FINAL_APP" ]]; then
  mkdir -p "$APP_ARCHIVE"
  mv \
    "$FINAL_APP" \
    "$APP_ARCHIVE/AI接入助手-${TARGET_ARCH}-$STAMP.app"
fi
mv "$APP" "$FINAL_APP"
record_build_stage complete
echo "$FINAL_APP"

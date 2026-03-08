#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LOCAL_BUILD_ROOT="$ROOT_DIR/.codex-build/local-install"
LOCAL_DERIVED_DATA="$LOCAL_BUILD_ROOT/deriveddata"
LOCAL_SPM_DIR="$LOCAL_BUILD_ROOT/spm"
INSTALL_APP_PATH="/Applications/Markdown.app"
LOCAL_CODESIGN_IDENTITY="${LOCAL_CODESIGN_IDENTITY:-Markdown}"

function require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Required tool not found: $1" >&2
    exit 1
  fi
}

require_tool security
require_tool xcodegen
require_tool xcodebuild

if ! security find-identity -v -p codesigning | grep -F "\"$LOCAL_CODESIGN_IDENTITY\"" >/dev/null; then
  "$ROOT_DIR/scripts/create_local_codesigning_identity.sh" "$LOCAL_CODESIGN_IDENTITY"
fi

rm -rf "$LOCAL_BUILD_ROOT"
mkdir -p "$LOCAL_BUILD_ROOT"

cd "$ROOT_DIR"
xcodegen
xcodebuild \
  -project MarkdownEditor.xcodeproj \
  -scheme MarkdownEditor \
  -configuration Debug \
  -xcconfig "$ROOT_DIR/LocalBuild.xcconfig" \
  -derivedDataPath "$LOCAL_DERIVED_DATA" \
  -clonedSourcePackagesDirPath "$LOCAL_SPM_DIR" \
  CODE_SIGN_IDENTITY="$LOCAL_CODESIGN_IDENTITY" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=YES \
  DEVELOPMENT_TEAM="" \
  build

APP_PATH="$LOCAL_DERIVED_DATA/Build/Products/Debug/Markdown.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "Local app not found at $APP_PATH" >&2
  exit 1
fi

pkill -x Markdown >/dev/null 2>&1 || true
rm -rf "$INSTALL_APP_PATH"
ditto "$APP_PATH" "$INSTALL_APP_PATH"
xattr -cr "$INSTALL_APP_PATH"
open -na "$INSTALL_APP_PATH"

echo "Installed local build to $INSTALL_APP_PATH"
echo "Signing identity: $LOCAL_CODESIGN_IDENTITY"
echo "Sparkle feed disabled for local installs"

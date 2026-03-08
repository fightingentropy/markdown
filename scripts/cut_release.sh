#!/bin/zsh
set -euo pipefail

function usage() {
  cat <<'EOF'
Usage: ./scripts/cut_release.sh [options]

Builds the current Release app, creates a Sparkle archive, regenerates the appcast,
and syncs the root appcast feed used by the app.

Options:
  --notes-file <path>               Copy release notes from this file to releases/Markdown-<version>.md
  --archives-dir <path>             Output directory for archives and generated appcast (default: releases)
  --derived-data-path <path>        Derived data path for the build (default: .derived)
  --download-url-prefix <url>       Public archive URL prefix (default: GitHub raw main/releases)
  --release-notes-url-prefix <url>  Public release notes URL prefix (default: same as download prefix)
  -h, --help                        Show this help
EOF
}

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ARCHIVES_DIR="$ROOT_DIR/releases"
DERIVED_DATA_PATH="$ROOT_DIR/.derived"
DOWNLOAD_URL_PREFIX="https://raw.githubusercontent.com/fightingentropy/markdown/main/releases"
RELEASE_NOTES_URL_PREFIX="$DOWNLOAD_URL_PREFIX"
NOTES_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --notes-file)
      NOTES_FILE="$2"
      shift 2
      ;;
    --archives-dir)
      ARCHIVES_DIR="$2"
      shift 2
      ;;
    --derived-data-path)
      DERIVED_DATA_PATH="$2"
      shift 2
      ;;
    --download-url-prefix)
      DOWNLOAD_URL_PREFIX="$2"
      shift 2
      ;;
    --release-notes-url-prefix)
      RELEASE_NOTES_URL_PREFIX="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

mkdir -p "$ARCHIVES_DIR"

cd "$ROOT_DIR"
xcodegen
xcodebuild \
  -project MarkdownEditor.xcodeproj \
  -scheme MarkdownEditor \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  build

APP_PATH="$DERIVED_DATA_PATH/Build/Products/Release/Markdown.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "Release app not found at $APP_PATH" >&2
  exit 1
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_PATH/Contents/Info.plist")
ARCHIVE_PATH="$ARCHIVES_DIR/Markdown-$VERSION.zip"
DEFAULT_NOTES_PATH="$ARCHIVES_DIR/Markdown-$VERSION.md"

if [[ -n "$NOTES_FILE" ]]; then
  if [[ "${NOTES_FILE:A}" != "${DEFAULT_NOTES_PATH:A}" ]]; then
    cp "$NOTES_FILE" "$DEFAULT_NOTES_PATH"
  fi
elif [[ ! -f "$DEFAULT_NOTES_PATH" ]]; then
  echo "Release notes missing: $DEFAULT_NOTES_PATH" >&2
  echo "Create that file or pass --notes-file <path>." >&2
  exit 1
fi

rm -f "$ARCHIVE_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ARCHIVE_PATH"

"$ROOT_DIR/scripts/generate_appcast.sh" \
  "$ARCHIVES_DIR" \
  "$DOWNLOAD_URL_PREFIX" \
  "$RELEASE_NOTES_URL_PREFIX"

echo "Built Markdown $VERSION ($BUILD)"
echo "Archive: $ARCHIVE_PATH"
echo "Release notes: $DEFAULT_NOTES_PATH"
echo "Appcast: $ARCHIVES_DIR/appcast.xml"
if [[ "${ARCHIVES_DIR:A}" == "${ROOT_DIR:A}/releases" ]]; then
  echo "Root feed: $ROOT_DIR/appcast.xml"
fi

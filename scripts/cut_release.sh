#!/bin/zsh
set -euo pipefail

function usage() {
  cat <<'EOF'
Usage: ./scripts/cut_release.sh [options]

Builds the current Release app, uploads Sparkle assets to GitHub Releases,
regenerates the appcast, and syncs the root appcast feed used by the app.

Environment:
  SPARKLE_PRIVATE_KEY               Required. Private Sparkle signing key used for this release
  SPARKLE_FEED_URL                  Optional. Feed URL embedded into the release app
  SPARKLE_KEY_ACCOUNT               Optional. Keychain account name used to derive the public key

Options:
  --notes-file <path>               Copy release notes from this file to releases/Markdown-<version>.md
  --archives-dir <path>             Local cache for archives and generated appcast (default: .release-assets)
  --derived-data-path <path>        Derived data path for the build (default: .release-build)
  --repo <owner/repo>               GitHub repository used for release uploads (default: current gh repo)
  --release-notes-url-prefix <url>  Public release notes URL prefix (default: GitHub raw main/releases)
  --skip-github-release             Build and generate a local appcast without uploading assets or touching root appcast
  -h, --help                        Show this help
EOF
}

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ARCHIVES_DIR="$ROOT_DIR/.release-assets"
DERIVED_DATA_PATH="$ROOT_DIR/.release-build"
REPO=""
RELEASE_NOTES_URL_PREFIX=""
NOTES_FILE=""
PUBLISH_GITHUB_RELEASE=true
SPARKLE_FEED_URL="${SPARKLE_FEED_URL:-}"
SPARKLE_PRIVATE_KEY="${SPARKLE_PRIVATE_KEY:-}"
SPARKLE_KEY_ACCOUNT="${SPARKLE_KEY_ACCOUNT:-}"

function require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Required tool not found: $1" >&2
    exit 1
  fi
}

function sync_release_notes() {
  mkdir -p "$ARCHIVES_DIR"
  rm -f "$ARCHIVES_DIR"/Markdown-*.md
  for notes in "$ROOT_DIR"/releases/Markdown-*.md(N); do
    cp "$notes" "$ARCHIVES_DIR/"
  done
}

function download_existing_release_assets() {
  local release_tags
  release_tags=("${(@f)$(gh release list --repo "$REPO" --limit 100 --json tagName --jq '.[].tagName' 2>/dev/null)}")

  for tag in "${release_tags[@]}"; do
    gh release download "$tag" \
      --repo "$REPO" \
      --pattern "*.zip" \
      --pattern "*.delta" \
      --dir "$ARCHIVES_DIR" \
      --clobber >/dev/null
  done
}

function upload_current_release_assets() {
  local tag="v$VERSION"
  local title="Markdown $VERSION"
  local delta_files=("$ARCHIVES_DIR"/Markdown${BUILD}-*.delta(N))

  if gh release view "$tag" --repo "$REPO" >/dev/null 2>&1; then
    gh release edit "$tag" --repo "$REPO" --title "$title" --notes-file "$DEFAULT_NOTES_PATH" >/dev/null
    if (( ${#delta_files[@]} > 0 )); then
      gh release upload "$tag" --repo "$REPO" "$ARCHIVE_PATH" "${delta_files[@]}" --clobber >/dev/null
    else
      gh release upload "$tag" --repo "$REPO" "$ARCHIVE_PATH" --clobber >/dev/null
    fi
  else
    if (( ${#delta_files[@]} > 0 )); then
      gh release create "$tag" --repo "$REPO" --title "$title" --notes-file "$DEFAULT_NOTES_PATH" "$ARCHIVE_PATH" "${delta_files[@]}" >/dev/null
    else
      gh release create "$tag" --repo "$REPO" --title "$title" --notes-file "$DEFAULT_NOTES_PATH" "$ARCHIVE_PATH" >/dev/null
    fi
  fi
}

function sync_root_appcast() {
  cp "$ARCHIVES_DIR/appcast.xml" "$ROOT_DIR/appcast.xml"
}

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
    --repo)
      REPO="$2"
      shift 2
      ;;
    --release-notes-url-prefix)
      RELEASE_NOTES_URL_PREFIX="$2"
      shift 2
      ;;
    --skip-github-release)
      PUBLISH_GITHUB_RELEASE=false
      shift 1
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

require_tool xcodegen
require_tool xcodebuild
require_tool python3

if [[ -z "$REPO" && ( "$PUBLISH_GITHUB_RELEASE" == true || -z "$RELEASE_NOTES_URL_PREFIX" ) ]]; then
  require_tool gh
  REPO="$(gh repo view --json nameWithOwner --jq '.nameWithOwner')"
fi

if [[ -z "$RELEASE_NOTES_URL_PREFIX" ]]; then
  if [[ -n "$REPO" ]]; then
    RELEASE_NOTES_URL_PREFIX="https://raw.githubusercontent.com/$REPO/main/releases"
  else
    RELEASE_NOTES_URL_PREFIX="https://example.invalid/releases"
  fi
fi

if [[ -z "$SPARKLE_FEED_URL" ]]; then
  if [[ -n "$REPO" ]]; then
    SPARKLE_FEED_URL="https://raw.githubusercontent.com/$REPO/main/appcast.xml"
  else
    SPARKLE_FEED_URL="https://example.invalid/appcast.xml"
  fi
fi

if [[ -z "$SPARKLE_PRIVATE_KEY" ]]; then
  echo "SPARKLE_PRIVATE_KEY must be set for release builds." >&2
  exit 1
fi

if [[ -z "$SPARKLE_KEY_ACCOUNT" ]]; then
  if [[ -n "$REPO" ]]; then
    SPARKLE_KEY_ACCOUNT="${REPO##*/}-sparkle"
  else
    SPARKLE_KEY_ACCOUNT="markdown-sparkle"
  fi
fi

mkdir -p "$ARCHIVES_DIR"
sync_release_notes

if [[ "$PUBLISH_GITHUB_RELEASE" == true ]]; then
  download_existing_release_assets
fi

cd "$ROOT_DIR"
xcodegen

if [[ -d "$DERIVED_DATA_PATH" ]]; then
  SPARKLE_BIN_DIR="$(find "$DERIVED_DATA_PATH" -path '*/artifacts/sparkle/Sparkle/bin' -type d | head -1)"
else
  SPARKLE_BIN_DIR=""
fi
if [[ -z "$SPARKLE_BIN_DIR" ]]; then
  xcodebuild \
    -project MarkdownEditor.xcodeproj \
    -scheme MarkdownEditor \
    -resolvePackageDependencies \
    -derivedDataPath "$DERIVED_DATA_PATH" >/dev/null
  SPARKLE_BIN_DIR="$(find "$DERIVED_DATA_PATH" -path '*/artifacts/sparkle/Sparkle/bin' -type d | head -1)"
fi

if [[ -z "$SPARKLE_BIN_DIR" ]]; then
  echo "Could not locate Sparkle binaries under $DERIVED_DATA_PATH" >&2
  exit 1
fi

SPARKLE_PRIVATE_KEY_FILE="$(mktemp "${TMPDIR:-/tmp}/markdown-sparkle-key.XXXXXX")"
cleanup() {
  rm -f "$SPARKLE_PRIVATE_KEY_FILE"
}
trap cleanup EXIT
printf '%s' "$SPARKLE_PRIVATE_KEY" > "$SPARKLE_PRIVATE_KEY_FILE"

"$SPARKLE_BIN_DIR/generate_keys" --account "$SPARKLE_KEY_ACCOUNT" -f "$SPARKLE_PRIVATE_KEY_FILE" >/dev/null
SPARKLE_PUBLIC_ED_KEY="$("$SPARKLE_BIN_DIR/generate_keys" --account "$SPARKLE_KEY_ACCOUNT" -p | tr -d '\n')"

if [[ -z "$SPARKLE_PUBLIC_ED_KEY" ]]; then
  echo "Could not derive Sparkle public key" >&2
  exit 1
fi

xcodebuild \
  -project MarkdownEditor.xcodeproj \
  -scheme MarkdownEditor \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  SPARKLE_FEED_URL="$SPARKLE_FEED_URL" \
  SPARKLE_PUBLIC_ED_KEY="$SPARKLE_PUBLIC_ED_KEY" \
  build

APP_PATH="$DERIVED_DATA_PATH/Build/Products/Release/Markdown.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "Release app not found at $APP_PATH" >&2
  exit 1
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_PATH/Contents/Info.plist")
ARCHIVE_PATH="$ARCHIVES_DIR/Markdown-$VERSION.zip"
DEFAULT_NOTES_PATH="$ROOT_DIR/releases/Markdown-$VERSION.md"

if [[ -n "$NOTES_FILE" ]]; then
  mkdir -p "$ROOT_DIR/releases"
  if [[ "${NOTES_FILE:A}" != "${DEFAULT_NOTES_PATH:A}" ]]; then
    cp "$NOTES_FILE" "$DEFAULT_NOTES_PATH"
  fi
elif [[ ! -f "$DEFAULT_NOTES_PATH" ]]; then
  echo "Release notes missing: $DEFAULT_NOTES_PATH" >&2
  echo "Create that file or pass --notes-file <path>." >&2
  exit 1
fi

cp "$DEFAULT_NOTES_PATH" "$ARCHIVES_DIR/"

rm -f "$ARCHIVE_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ARCHIVE_PATH"

if [[ "$PUBLISH_GITHUB_RELEASE" == true ]]; then
  upload_current_release_assets
fi

SPARKLE_BIN="$SPARKLE_BIN_DIR/generate_appcast" \
"$ROOT_DIR/scripts/generate_appcast.sh" \
  "$ARCHIVES_DIR" \
  "https://example.invalid/releases" \
  "$RELEASE_NOTES_URL_PREFIX" \
  "$SPARKLE_PRIVATE_KEY_FILE"

if [[ "$PUBLISH_GITHUB_RELEASE" == true ]]; then
  python3 "$ROOT_DIR/scripts/rewrite_appcast_for_github_releases.py" "$ARCHIVES_DIR/appcast.xml" "$REPO"
  sync_root_appcast
fi

echo "Built Markdown $VERSION ($BUILD)"
echo "Archive cache: $ARCHIVE_PATH"
echo "Release notes: $DEFAULT_NOTES_PATH"
echo "Appcast cache: $ARCHIVES_DIR/appcast.xml"
if [[ "$PUBLISH_GITHUB_RELEASE" == true ]]; then
  echo "Root feed: $ROOT_DIR/appcast.xml"
  echo "GitHub release: https://github.com/$REPO/releases/tag/v$VERSION"
else
  echo "Root feed unchanged (--skip-github-release)"
fi

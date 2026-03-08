#!/bin/zsh
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <archives-dir> [download-url-prefix] [release-notes-url-prefix]" >&2
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ARCHIVES_DIR="$1"
DOWNLOAD_URL_PREFIX="${2:-https://raw.githubusercontent.com/fightingentropy/markdown/main/releases}"
RELEASE_NOTES_URL_PREFIX="${3:-https://raw.githubusercontent.com/fightingentropy/markdown/main/releases}"
SPARKLE_BIN="$ROOT_DIR/.derived/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast"
OUTPUT_APPCAST="$ARCHIVES_DIR/appcast.xml"

if [[ ! -x "$SPARKLE_BIN" ]]; then
  echo "Sparkle generate_appcast tool not found at $SPARKLE_BIN" >&2
  exit 1
fi

"$SPARKLE_BIN" \
  --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
  --release-notes-url-prefix "$RELEASE_NOTES_URL_PREFIX" \
  --link "https://github.com/fightingentropy/markdown" \
  "$ARCHIVES_DIR"

if [[ "${ARCHIVES_DIR:A}" == "${ROOT_DIR:A}/releases" && -f "$OUTPUT_APPCAST" ]]; then
  cp "$OUTPUT_APPCAST" "$ROOT_DIR/appcast.xml"
  echo "Synced $ROOT_DIR/appcast.xml"
fi

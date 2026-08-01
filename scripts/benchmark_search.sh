#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

PROFILE="full"
if [[ "${1:-}" == "--smoke" ]]; then
  PROFILE="smoke"
elif [[ -n "${1:-}" && "${1:-}" != "--full" ]]; then
  echo "usage: scripts/benchmark_search.sh [--smoke|--full]" >&2
  exit 64
fi

xcodegen generate --quiet --spec project.yml
echo "Running $PROFILE search benchmark profile"
XCODE_SETTINGS=("CODE_SIGNING_ALLOWED=NO")
if [[ "$PROFILE" == "full" ]]; then
  XCODE_SETTINGS+=("SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG MARKDOWN_SEARCH_BENCHMARK_FULL")
fi
xcodebuild test \
  -project MarkdownEditor.xcodeproj \
  -scheme MarkdownEditor \
  -destination 'platform=macOS' \
  -only-testing:MarkdownEditorTests/SearchBenchmarkTests \
  "${XCODE_SETTINGS[@]}"

#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

python3 scripts/check_docs.py
xcodegen generate --quiet --spec project.yml

xcodebuild -resolvePackageDependencies \
  -project Obsidian.xcodeproj \
  -scheme Obsidian
git diff --exit-code -- \
  Obsidian.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
xcodebuild test \
  -project Obsidian.xcodeproj \
  -scheme Obsidian \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO

#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
scroll_test_dir="$(mktemp -d)"
trap 'rm -rf "$scroll_test_dir"' EXIT
xcrun swiftc -O -swift-version 5 -default-isolation MainActor \
    SuperClipboard/ClipboardPreviewCache.swift SuperClipboard/ClipboardTextAppearance.swift \
    Scripts/Tests/ClipboardPreviewTests.swift -o "$scroll_test_dir/preview-tests"
"$scroll_test_dir/preview-tests"

#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
capture_derived="${1:-/tmp/SuperClipboardDerived}"
capture_products="$capture_derived/Build/Products/Debug"
capture_modulemap="$capture_derived/Build/Intermediates.noindex/GeneratedModuleMaps/ObjCExceptionCatcher.modulemap"
capture_test_dir="$(mktemp -d)"
trap 'rm -rf "$capture_test_dir"' EXIT
xcrun swiftc -swift-version 5 -default-isolation MainActor -I "$capture_products" \
    -Xcc "-fmodule-map-file=$capture_modulemap" \
    SuperClipboard/ClipboardStore.swift SuperClipboard/ClipboardListSession.swift SuperClipboard/NotebookStorage.swift \
    SuperClipboard/ClipboardTextAppearance.swift SuperClipboard/ClipboardPreviewCache.swift \
    Scripts/Tests/ClipboardCaptureTests.swift "$capture_products/MediaToolSwift.o" "$capture_products/ObjCExceptionCatcher.o" \
    -o "$capture_test_dir/capture-tests"
"$capture_test_dir/capture-tests"

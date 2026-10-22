#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
notebook_derived="${1:-/tmp/SuperClipboardDerived}"
notebook_products="$notebook_derived/Build/Products/Debug"
notebook_modulemap="$notebook_derived/Build/Intermediates.noindex/GeneratedModuleMaps/ObjCExceptionCatcher.modulemap"
if [[ ! -f "$notebook_products/MediaToolSwift.o" ]]; then
    echo "Build the macOS Debug scheme first, then pass its derived data directory as argument 1." >&2
    exit 1
fi
notebook_test_dir="$(mktemp -d)"
trap 'rm -rf "$notebook_test_dir"' EXIT
xcrun swiftc SuperClipboard/NotebookStorage.swift Scripts/Tests/NotebookStorageTests.swift -o "$notebook_test_dir/storage-tests"
"$notebook_test_dir/storage-tests"
xcrun swiftc -swift-version 5 -default-isolation MainActor -I "$notebook_products" \
    -Xcc "-fmodule-map-file=$notebook_modulemap" \
    SuperClipboard/ClipboardStore.swift SuperClipboard/ClipboardListSession.swift SuperClipboard/NotebookStorage.swift SuperClipboard/ClipboardTextAppearance.swift SuperClipboard/ClipboardPreviewCache.swift \
    Scripts/Tests/NotebookStoreTests.swift "$notebook_products/MediaToolSwift.o" "$notebook_products/ObjCExceptionCatcher.o" \
    -o "$notebook_test_dir/store-tests"
"$notebook_test_dir/store-tests"

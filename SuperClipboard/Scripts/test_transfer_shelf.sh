#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
transfer_derived="${1:-/tmp/SuperClipboardDerived}"
transfer_products="$transfer_derived/Build/Products/Debug"
transfer_modulemap="$transfer_derived/Build/Intermediates.noindex/GeneratedModuleMaps/ObjCExceptionCatcher.modulemap"
transfer_test_dir="$(mktemp -d)"
trap 'rm -rf "$transfer_test_dir"' EXIT
xcrun swiftc -swift-version 5 -default-isolation MainActor -I "$transfer_products" \
    -Xcc "-fmodule-map-file=$transfer_modulemap" \
    SuperClipboard/ClipboardStore.swift SuperClipboard/ClipboardListSession.swift SuperClipboard/NotebookStorage.swift \
    SuperClipboard/ClipboardTextAppearance.swift SuperClipboard/ClipboardPreviewCache.swift \
    Scripts/Tests/TransferShelfTests.swift "$transfer_products/MediaToolSwift.o" "$transfer_products/ObjCExceptionCatcher.o" \
    -o "$transfer_test_dir/transfer-tests"
"$transfer_test_dir/transfer-tests"
xcrun swiftc -swift-version 5 -default-isolation MainActor \
    SuperClipboard/AppWindowCoordinator.swift SuperClipboard/ClipboardTheme.swift Scripts/Tests/AppWindowLifecycleTests.swift \
    -o "$transfer_test_dir/window-tests"
"$transfer_test_dir/window-tests"

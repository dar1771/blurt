#!/usr/bin/env bash
# Exercise shell adapters without the user's general clipboard, Keychain or network.
# First build the app, then pass its derived-data directory as the only argument.
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: scripts/clipboard-sync-smoke.sh <app-derived-data-directory>" >&2
  exit 2
fi

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
products="$1/Build/Products/Debug"
if [[ ! -f "$products/BlurtEngine.o" ]]; then
  echo "error: build the Debug app first; missing $products/BlurtEngine.o" >&2
  exit 1
fi

smoke_dir="$(mktemp -d "${TMPDIR:-/tmp}/clipboard-sync-smoke.XXXXXX")"
trap 'rm -rf "$smoke_dir"' EXIT
for suite in smoke review; do
  xcrun swiftc -parse-as-library -swift-version 6 -target "$(uname -m)-apple-macos13.0" \
    -profile-generate -profile-coverage-mapping \
    -I "$products" -module-cache-path "$smoke_dir/module-cache" \
    "$products/BlurtEngine.o" \
    "$repo_root/App/Blurt/Blurt/ClipboardSync/ClipboardSyncPasteboard.swift" \
    "$repo_root/App/Blurt/Blurt/ClipboardSync/ClipboardSyncFiles.swift" \
    "$repo_root/App/Blurt/Blurt/ClipboardSync/ClipboardSyncStorage.swift" \
    "$repo_root/scripts/clipboard-sync-$suite.swift" \
    -o "$smoke_dir/$suite"
  LLVM_PROFILE_FILE="$smoke_dir/$suite.profraw" "$smoke_dir/$suite"
done

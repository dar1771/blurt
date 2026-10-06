#!/usr/bin/env bash
# Verify UI-test history stays in memory without opening personal History.sqlite.
# First build the Debug app, then pass its derived-data directory.
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: scripts/history-isolation-smoke.sh <app-derived-data-directory>" >&2
  exit 2
fi

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
products="$1/Build/Products/Debug"
if [[ ! -f "$products/BlurtEngine.o" ]]; then
  echo "error: build the Debug app first; missing $products/BlurtEngine.o" >&2
  exit 1
fi

smoke_dir="$(mktemp -d "${TMPDIR:-/tmp}/history-isolation-smoke.XXXXXX")"
trap 'rm -rf "$smoke_dir"' EXIT
xcrun swiftc -parse-as-library -swift-version 6 -target "$(uname -m)-apple-macos13.0" \
  -profile-generate -profile-coverage-mapping \
  -I "$products" -module-cache-path "$smoke_dir/module-cache" \
  "$products/BlurtEngine.o" \
  "$repo_root/App/Blurt/Blurt/History/HistoryModel.swift" \
  "$repo_root/App/Blurt/Blurt/History/HistoryModel+Operations.swift" \
  "$repo_root/App/Blurt/Blurt/History/HistoryModel+Processing.swift" \
  "$repo_root/scripts/history-isolation-smoke.swift" \
  -o "$smoke_dir/smoke"
LLVM_PROFILE_FILE="$smoke_dir/smoke.profraw" "$smoke_dir/smoke"

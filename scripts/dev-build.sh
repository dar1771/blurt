#!/usr/bin/env bash
# Build VibeDictate Dev.app for local development and install it to /Applications.
#
# Unlike check.sh (which builds with codesigning DISABLED for CI), this runs a
# fully signed build so the project.yml postBuildScripts "Install to
# /Applications" step actually fires — copying the bundle to /Applications
# (or ~/Applications fallback) and re-signing it with your Apple Development
# cert. That stable install path is required for TCC to register Accessibility /
# Input-Monitoring / Microphone grants (DerivedData/tmp paths never do).
#
# It installs as "VibeDictate Dev.app" under the bundle id app.vibedictate.dev, so it
# sits beside a release instead of replacing it: separate Privacy &
# Security rows, separate settings, either one runnable. Grant the dev app its
# own permissions once and they stick across rebuilds.
#
# Set VIBEDICTATE_DEVELOPMENT_TEAM to sign with a different local Apple
# Development team (for example, a contributor's Personal Team). The release
# team's setting in project.yml remains unchanged.
#
# Pipes xcodebuild through xcbeautify when available (brew install xcbeautify).
# Safe to re-run.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$REPO_ROOT/App/Blurt"
DERIVED_BASE="/tmp/blurt-build"

# shellcheck source=scripts/release-lib.sh
source "$REPO_ROOT/scripts/release-lib.sh"

require_tools xcodebuild

pretty_xcodebuild

cd "$APP_DIR"

DERIVED="$DERIVED_BASE"
if [ -d "$DERIVED" ]; then
  info "Clearing DerivedData ($DERIVED)"
  if ! rm -rf "$DERIVED"; then
    DERIVED="$(mktemp -d /tmp/blurt-build.XXXXXX)"
    info "DerivedData was busy; using fresh temp dir instead ($DERIVED)"
  fi
fi

info "Building VibeDictate Dev (Debug-Local) from clean and installing to /Applications"
set -o pipefail
# The Debug-Local configuration is a debug build with UITEST_HOOKS off (defined
# in project.yml), so this local build excludes the XCUITest harness and the
# leak/hotkey test seams — it's the real app, nothing test-runner-related.
# Selecting it by name (rather than overriding SWIFT_ACTIVE_COMPILATION_CONDITIONS
# on the command line) keeps the override off SwiftPM dependency targets: a
# command-line build-setting override applies to every target and replaces its
# value, silently stripping any compilation conditions the dependency packages
# set for themselves.
# The build action already builds only Blurt.app, not the BlurtUITests bundle.
xcodebuild \
  -project Blurt.xcodeproj \
  -scheme Blurt \
  -configuration Debug-Local \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" \
  "DEVELOPMENT_TEAM=${VIBEDICTATE_DEVELOPMENT_TEAM:-B2VQF7Q2QY}" \
  clean build | "${PRETTY[@]}"

installed_app="/Applications/VibeDictate Dev.app"
if [ ! -d "$installed_app" ]; then
  installed_app="$HOME/Applications/VibeDictate Dev.app"
fi

# Copying a new bundle does not replace a process already running from it.
# Restart it here so a manual acceptance test cannot exercise yesterday's code.
running_pids="$(pgrep -f "$installed_app/Contents/MacOS/Blurt" || true)"
if [ -n "$running_pids" ]; then
  info "Restarting the running VibeDictate Dev to load the installed build"
  while IFS= read -r running_pid; do
    kill -TERM "$running_pid"
  done <<< "$running_pids"
  sleep 2
  open -a "$installed_app"
fi

info "Done. Launch with: open -a 'VibeDictate Dev'"

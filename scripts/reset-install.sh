#!/usr/bin/env bash
set -euo pipefail

# The terminal half of a VibeDictate reset. The in-app reset clears the
# AssemblyAI key only; this script also clears the OpenRouter key. Settings
# > Advanced > Reset uses the engine's `InstallReset`. This script stays
# the fuller one: it covers *both* bundle ids (a running copy can only reset its
# own) and unregisters stale app copies from LaunchServices, neither of which an
# app can meaningfully do to itself.

# Both bundle ids VibeDictate ships under. Lowercase to match how macOS records the
# Accessibility TCC client (see the PRODUCT_BUNDLE_IDENTIFIER note in
# App/Blurt/project.yml), where the split is also explained: releases are
# `app.vibedictate`, every debug configuration is `app.vibedictate.dev`, so a dev
# build is a separate app with its own permissions, defaults and install path.
# The first must match `HostIdentity.vibeDictate.subsystem`
# (Sources/BlurtEngine/HostIdentity.swift) — the code's single definition of
# this string. A full reset means both: this script exists to get back to a
# clean preinstall state, and leaving half the state behind is how you end up
# debugging the other build's leftovers.
BUNDLE_IDS=("app.vibedictate" "app.vibedictate.dev")

# Quit Blurt first, or every step below is unreliable: a running instance
# keeps its defaults cached in cfprefsd (which rewrites the plist on quit,
# undoing `defaults delete`), can re-acquire TCC grants, and can rewrite the
# keychain item. killall (not AppleScript `quit`) avoids prompting the calling
# terminal for Automation permission. One name covers both builds: PRODUCT_NAME
# stays `Blurt` in every configuration, so both executables are called `Blurt`.
echo "==> Quitting VibeDictate if running"
killall Blurt 2>/dev/null || true

for bundle_id in "${BUNDLE_IDS[@]}"; do
  echo "==> Resetting TCC permissions for $bundle_id"
  # Microphone (recording), Accessibility (typing into other apps), and
  # ListenEvent / Input Monitoring (the CGEventTap that backs the hold-to-dictate
  # hotkey — see DictationKeyTap).
  tccutil reset Accessibility "$bundle_id" || true
  tccutil reset Microphone "$bundle_id" || true
  tccutil reset ListenEvent "$bundle_id" || true
done

echo "==> Removing duplicate LaunchServices registrations"
# Repeated builds leave VibeDictate.app / VibeDictate Dev.app copies in DerivedData, /tmp,
# periphery caches, and other checkouts — all claiming one of the bundle ids.
# macOS then resolves an id to a transient copy TCC refuses to register, so
# Blurt silently vanishes from the Accessibility list. Unregister every copy,
# then re-register only the canonical installs so each id resolves to a stable
# path.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "$LSREGISTER" ]; then
  # Exactly the two bundle names, via an optional " Dev" (POSIX BRE interval, so
  # BSD and GNU sed agree). A looser `Blurt[^/]*\.app` would also sweep
  # BlurtUITests-Runner.app — a bundle this script neither owns nor re-registers.
  "$LSREGISTER" -dump 2>/dev/null \
    | sed -n 's/^[[:space:]]*path:[[:space:]]*\(.*\/VibeDictate\( Dev\)\{0,1\}\.app\) (0x[0-9a-f]*)$/\1/p' \
    | sort -u \
    | while IFS= read -r app; do
      "$LSREGISTER" -u "$app" >/dev/null 2>&1 && echo "    unregistered: $app" || true
    done || echo "    note: lsregister dump failed; skipping unregister sweep"
  for dest in "/Applications/VibeDictate.app" "$HOME/Applications/VibeDictate.app" \
    "/Applications/VibeDictate Dev.app" "$HOME/Applications/VibeDictate Dev.app"; do
    [ -d "$dest" ] && "$LSREGISTER" -f "$dest" >/dev/null 2>&1 && echo "    registered: $dest" || true
  done
fi

for bundle_id in "${BUNDLE_IDS[@]}"; do
  echo "==> Clearing UserDefaults for $bundle_id"
  defaults delete "$bundle_id" 2>/dev/null || true
done

# AssemblyAI API key lives in the login keychain as a generic password. Keychain
# items are per login keychain rather than per app, so the two builds are NOT
# separated by their bundle ids the way their defaults and TCC rows are: each one
# names its own service. These must match `HostIdentity.vibeDictate.keychainService`
# and `HostIdentity.vibeDictateDev.keychainService` (Sources/BlurtEngine/HostIdentity.swift,
# used by APIKeyStore); `HostIdentityTests` pins both, so a rename there fails
# `swift test` until this list is updated with it.
KEYCHAIN_SERVICES=("vibedictate" "vibedictate-dev")
KEYCHAIN_ACCOUNTS=("AssemblyAIAPIKey" "OpenRouterAPIKey")
for keychain_service in "${KEYCHAIN_SERVICES[@]}"; do
  for keychain_account in "${KEYCHAIN_ACCOUNTS[@]}"; do
    echo "==> Deleting API key from Keychain ($keychain_service / $keychain_account)"
    security delete-generic-password -s "$keychain_service" -a "$keychain_account" >/dev/null 2>&1 || true
  done
done

# Developer mode appends transcript and failure logs here (see DictationLog); a
# fresh install has neither, so clear them too. The rmdir below only succeeds
# once the directory is empty, so every file Blurt writes there must be listed.
DICTATION_LOG_DIR="$HOME/Library/Logs/VibeDictate"
echo "==> Removing dictation logs ($DICTATION_LOG_DIR/{dictations,errors}.jsonl)"
rm -f "$DICTATION_LOG_DIR/dictations.jsonl" "$DICTATION_LOG_DIR/errors.jsonl"
rmdir "$DICTATION_LOG_DIR" 2>/dev/null || true

echo "Done. Relaunch VibeDictate for permission prompts to reappear."

# Saved audio and History.sqlite are intentionally retained, like the in-app reset.

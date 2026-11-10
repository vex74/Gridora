#!/bin/bash
# Build Gridora.app from the Swift package. The executable inside the bundle
# stays "LaunchOS" (a persisted technical identifier); only the bundle's
# file/display name is Gridora.
set -euo pipefail
cd "$(dirname "$0")"

# Usage: ./build.sh [debug|release] [--install]  (or just ./build.sh --install)
if [ "${1:-}" = "--install" ]; then
  CONFIG="release"
  set -- release --install
else
  CONFIG="${1:-release}"
fi
# macOS 27.2's SwiftUI declares @State as an external macro
# (SwiftUIMacros.StateMacro), but the Command Line Tools toolchain does not
# ship libSwiftUIMacros.dylib. Compiling against that SDK fails every SwiftUI
# file with "plugin for module 'SwiftUIMacros' not found", even for a bare
# `swiftc -typecheck`. Pin to the newest SDK where @State is still a property
# wrapper; the produced binary still runs fine on newer macOS (SwiftUI is a
# system framework). Override with LAUNCHOS_SDK if the toolchain is fixed.
if [ -z "${LAUNCHOS_SDK:-}" ]; then
  CLT_SDKS=/Library/Developer/CommandLineTools/SDKs
  for candidate in MacOSX26.5.sdk MacOSX26.sdk MacOSX15.2.sdk; do
    if [ -d "$CLT_SDKS/$candidate" ]; then
      LAUNCHOS_SDK="$CLT_SDKS/$candidate"
      break
    fi
  done
fi
if [ -n "${LAUNCHOS_SDK:-}" ]; then
  export SDKROOT="$LAUNCHOS_SDK"
  echo "SDKROOT=$SDKROOT"
fi

# SwiftPM's manifest sandbox cannot be nested inside a hardened/CI sandbox
# (sandbox_apply: Operation not permitted). Skipping it is harmless here —
# the manifest only declares the package, it never runs untrusted code.
swift build -c "$CONFIG" --disable-sandbox

BIN=".build/$CONFIG/LaunchOS"
APP="build/Gridora.app"

rm -rf "$APP"
rm -rf build/LaunchOS.app   # drop the pre-rename build artifact
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/LaunchOS"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

# Finder/FinderInfo xattrs make codesign reject the bundle ("resource fork,
# Finder information, or similar detritus not allowed"). Clear them first.
# Never swallow the signing error: a bundle without a proper seal fails
# `codesign --verify` and Gatekeeper reports it as damaged.
xattr -cr "$APP" 2>/dev/null || true
codesign --force --deep --sign - --identifier com.vex.launchos --timestamp=none "$APP"
# The Finder re-attaches FinderInfo/fpfs#P/macl to anything under ~/Desktop
# within milliseconds; --strict rejects those as detritus even though the seal
# itself is fine. Non-strict `--deep` is the check Gatekeeper actually uses and
# MUST always pass. --strict is best-effort informational only: never abort a
# build (or an --install delivery) because of a transient Finder xattr.
xattr -cr "$APP" 2>/dev/null || true
if ! codesign --verify --deep "$APP" >/dev/null 2>&1; then
  codesign --verify --deep "$APP"   # loud failure, set -e aborts
fi
strict_ok=0
for _ in 1 2 3 4 5; do
  xattr -cr "$APP" 2>/dev/null || true
  if codesign --verify --deep --strict "$APP" 2>/dev/null; then
    strict_ok=1
    break
  fi
done
if [ "$strict_ok" -eq 1 ]; then
  echo "Signature: deep + strict OK"
else
  echo "Signature: deep OK (strict transient: Finder re-attached FinderInfo)"
fi

echo "Built $APP"

# One-command delivery: ./build.sh release --install
# Swaps build/Gridora.app into /Applications and ~/Desktop/Gridora.app with a
# clean (non-overwriting) replacement. Without this, the Dock tile pinned to the
# desktop bundle goes stale after every update.
if [ "${2:-}" = "--install" ]; then
  exec bash Scripts/install.sh "$APP"
fi

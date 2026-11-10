#!/bin/bash
# Install a freshly built Gridora.app into the two places the user actually
# launches it from. Future updates only need:
#
#   ./build.sh release --install          (build + swap in one command)
#   ./Scripts/install.sh                 (swap an already-built bundle)
#   ./Scripts/install.sh /path/to/Gridora.app
#
# Why this script exists: copying a new .app ON TOP of an existing bundle leaves
# stale resources behind and breaks the code seal (Gatekeeper then reports the
# app as damaged). ~/Desktop also gets FinderInfo/fpfs#P/macl xattrs re-attached
# by Finder, which makes `codesign --verify --deep --strict` fail transiently.
# So: move the old bundle aside (never delete), copy into a fresh path, clear
# xattrs, re-sign adhoc, verify with retries, and re-register with LaunchServices.
# The Dock tile is pinned to ~/Desktop/Gridora.app -- that path must always
# exist and must always be a launchable, signed bundle. Finder/Dock display the
# bundle FILE name, so the file had to be renamed together with CFBundleName.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:-$ROOT/build/Gridora.app}"
[[ "$SRC" = /* ]] || SRC="$ROOT/$SRC"

DESKTOP="$HOME/Desktop/Gridora.app"
APPLICATIONS="/Applications/Gridora.app"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/tmp/Gridora-install-$STAMP"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
IDENTIFIER="com.vex.launchos"

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "  $*"; }

[ -d "$SRC/Contents" ] || die "not an app bundle: $SRC"
[ -f "$SRC/Contents/MacOS/LaunchOS" ] || die "missing executable: $SRC"
[ -f "$SRC/Contents/Resources/AppIcon.icns" ] || die "missing AppIcon.icns (Dock/Desktop icon): $SRC"

plutil -extract CFBundleIdentifier raw "$SRC/Contents/Info.plist" 2>/dev/null | grep -qx "$IDENTIFIER" \
  || die "unexpected bundle identifier in $SRC"
plutil -extract LSUIElement raw "$SRC/Contents/Info.plist" 2>/dev/null | grep -qx true \
  || die "LSUIElement must be true (no Dock running indicator)"

# ~/Desktop lives under Finder/FileProvider: FinderInfo and fpfs#P xattrs are
# re-attached within milliseconds. Non-strict `--deep` is the check Gatekeeper
# actually uses and always passes; `--strict` is best-effort informational.
seal_ok() { codesign --verify --deep "$1" >/dev/null 2>&1; }
xattr -cr "$SRC" 2>/dev/null || true
seal_ok "$SRC" || die "source bundle fails signature verification (Gatekeeper path): $SRC"

SRC_SHA="$(shasum -a 256 "$SRC/Contents/MacOS/LaunchOS" | awk '{print $1}')"
echo "Source : $SRC"
echo "SHA256 : $SRC_SHA"

backup_old() {
  local dest="$1" label="$2" target="" n=1
  target="$BACKUP/$label-Gridora.app"
  mkdir -p "$BACKUP"
  while [ -e "$target" ]; do
    n=$((n + 1))
    target="$BACKUP/$label-Gridora-$n.app"
  done
  mv "$dest" "$target"
  log "$label: old bundle moved to $target"
}

verify_bundle() {
  local dest="$1" strict_ok=0
  seal_ok "$dest" || die "signature verification failed (Gatekeeper path): $dest"
  for _ in 1 2 3 4 5; do
    xattr -cr "$dest" 2>/dev/null || true
    if codesign --verify --deep --strict "$dest" 2>/dev/null; then strict_ok=1; break; fi
  done
  if [ "$strict_ok" -eq 1 ]; then
    log "deep + strict verify passed"
  else
    log "deep verify passed; strict transient (FinderInfo re-attached, not a bad seal)"
  fi
}

install_one() {
  local dest="$1" label="$2" cur=""
  echo "[$label] $dest"
  if [ -L "$dest" ] || [ -e "$dest" ]; then
    if [ -f "$dest/Contents/MacOS/LaunchOS" ]; then
      cur="$(shasum -a 256 "$dest/Contents/MacOS/LaunchOS" | awk '{print $1}')"
    fi
    if [ "${LAUNCHOS_FORCE_INSTALL:-0}" != "1" ] && [ "$cur" = "$SRC_SHA" ] \
       && seal_ok "$dest"; then
      log "already this build and seal is valid; left untouched"
    else
      backup_old "$dest" "$label"
    fi
  fi

  if [ ! -d "$dest" ]; then
    # Fresh destination path: no stale resources, no seal leftovers.
    ditto --norsrc --noextattr --noqtn "$SRC" "$dest"
    # ditto already carries the source's valid adhoc seal. Re-signing is only
    # belt-and-braces, and on ~/Desktop Finder re-attaches FinderInfo within
    # milliseconds, so `codesign --force --deep --sign` can fail with
    # "resource fork, Finder information, or similar detritus not allowed".
    # Never let that abort the install: retry, then keep the carried seal and
    # let verify_bundle() be the authority on whether the bundle is good.
    local signed=0
    for _ in 1 2 3 4 5; do
      xattr -cr "$dest" 2>/dev/null || true
      if codesign --force --deep --sign - --identifier "$IDENTIFIER" --timestamp=none "$dest" >/dev/null 2>&1; then
        signed=1
        break
      fi
    done
    if [ "$signed" -eq 1 ]; then
      log "installed fresh bundle + adhoc re-signed"
    else
      log "installed fresh bundle (kept ditto-carried seal; re-sign blocked by Finder xattrs)"
    fi
  fi

  verify_bundle "$dest"
  [ -f "$dest/Contents/MacOS/LaunchOS" ] || die "bundle incomplete: $dest"
  local got
  got="$(shasum -a 256 "$dest/Contents/MacOS/LaunchOS" | awk '{print $1}')"
  [ "$got" = "$SRC_SHA" ] || die "$label binary SHA mismatch ($got)"
  "$LSREGISTER" -f "$dest" >/dev/null 2>&1 || true
  # A freshly created bundle has no Spotlight record yet (mdls returns null for
  # a moment), which can make Finder/Dock show a generic icon right after an
  # update. Index it explicitly so the app icon is immediate.
  mdimport "$dest" >/dev/null 2>&1 || true
  log "OK  sha=${got:0:12}…  deep verify passed  LaunchServices + Spotlight refreshed"
}

# One-time rebrand migration: retire the pre-rename bundles so Desktop and
# /Applications never show two icons. Move (never delete) into the backup dir.
retire_legacy() {
  local legacy="$1" label="$2" target=""
  target="$BACKUP/legacy-$label-LaunchOS.app"
  if [ -e "$legacy" ] || [ -L "$legacy" ]; then
    mkdir -p "$BACKUP"
    mv "$legacy" "$target"
    log "$label: pre-rename LaunchOS.app moved to $target"
  fi
}
retire_legacy "$HOME/Desktop/LaunchOS.app" "Desktop"
retire_legacy "/Applications/LaunchOS.app" "Applications"

install_one "$APPLICATIONS" "Applications"
install_one "$DESKTOP" "Desktop"

# Hard post-conditions: the desktop icon must exist and the Dock tile must
# still point at it. Never rewrite Dock preferences here -- only warn.
[ -d "$DESKTOP" ] || die "desktop icon was not restored: $DESKTOP"
if defaults read com.apple.dock persistent-apps 2>/dev/null | grep -q "Desktop/Gridora.app"; then
  log "Dock tile still targets ~/Desktop/Gridora.app"
else
  log "NOTE: no Dock tile pinned to ~/Desktop/Gridora.app (drag the desktop icon to Dock if wanted)"
fi

if [ "${LAUNCHOS_REFRESH_DOCK:-0}" = "1" ]; then
  killall Dock >/dev/null 2>&1 || true
  log "Dock restarted to refresh the pinned icon"
fi

echo
echo "Done. Desktop : $DESKTOP"
echo "      Apps    : $APPLICATIONS"
if [ -d "$BACKUP" ]; then echo "      Backups : $BACKUP"; else echo "      Backups : (none needed)"; fi

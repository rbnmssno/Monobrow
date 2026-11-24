#!/bin/bash
# Builds Monobrow.app and Monobrow.dmg into dist/.
# Usage: scripts/build.sh            build the app and the disk image
#        scripts/build.sh --app-only build only dist/Monobrow.app
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP="dist/Monobrow.app"
DMG="dist/Monobrow.dmg"

# 1. Compile.
echo "==> Compiling"
swift build -c release --arch arm64 2>&1 | grep -E "error:|warning:|Build complete" || true
BIN="$(swift build -c release --arch arm64 --show-bin-path)/Monobrow"
[ -x "$BIN" ] || { echo "build failed"; exit 1; }

# 2. Assemble the app bundle.
echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Monobrow"
strip -x "$APP/Contents/MacOS/Monobrow"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
# The language folders tell macOS which languages the app speaks; it then picks one for the
# app's own texts and for system-provided ones (menus, dialogs).
cp -R Resources/en.lproj Resources/ru.lproj "$APP/Contents/Resources/"

# 3. Icon. The source is the Icon Composer document Resources/AppIcon.icon. Xcode's actool turns
#    it into Assets.car, which macOS 26 and later draw with their own glass and dark variants, and
#    AppIcon.icns for older systems. Without Xcode the prebuilt Resources/AppIcon.icns is used.
ICON_WORK="$(mktemp -d)"
# actool hands the work to a background agent with its own working directory, so paths are absolute.
if xcrun --find actool >/dev/null 2>&1 && xcrun actool "$ROOT/Resources/AppIcon.icon" --compile "$ROOT/$APP/Contents/Resources" \
     --platform macosx --minimum-deployment-target 14.0 --app-icon AppIcon \
     --output-partial-info-plist "$ICON_WORK/icon.plist" >"$ICON_WORK/actool.log" 2>&1; then
  echo "==> Icon compiled from Resources/AppIcon.icon"
else
  echo "==> actool unavailable; using the prebuilt Resources/AppIcon.icns"
  rm -f "$APP/Contents/Resources/Assets.car"
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
rm -rf "$ICON_WORK"

# 4. Sign locally (ad hoc). No developer certificate is needed to run it on this Mac.
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict "$APP"

if [ "${1:-}" = "--app-only" ]; then
  echo "==> Done: $APP"
  exit 0
fi

# 5. Disk image with the app and a shortcut to Applications.
echo "==> Creating $DMG"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/Monobrow.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
# hdiutil prints a deprecation notice on new systems; show its output only if it fails.
if ! hdiutil create -volname "Monobrow" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >"$STAGE.log" 2>&1; then
  cat "$STAGE.log"
  rm -rf "$STAGE" "$STAGE.log"
  exit 1
fi
rm -rf "$STAGE" "$STAGE.log"
echo "==> Done: $DMG ($(du -h "$DMG" | cut -f1))"

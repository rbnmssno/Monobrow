#!/bin/bash
# Builds Monobrow.app and Monobrow.dmg into dist/.
# Usage: scripts/build.sh            build the app and the disk image
#        scripts/build.sh --app-only build only dist/Monobrow.app
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP="dist/Monobrow.app"
DMG="dist/Monobrow.dmg"
ICON="Resources/AppIcon.icns"

# 1. Icon (generated once, then reused).
if [ ! -f "$ICON" ]; then
  echo "==> Drawing the icon"
  WORK="$(mktemp -d)"
  swift scripts/make-icon.swift "$WORK/icon-1024.png"
  SET="$WORK/AppIcon.iconset"
  mkdir -p "$SET"
  for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$WORK/icon-1024.png" --out "$SET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$WORK/icon-1024.png" --out "$SET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$SET" -o "$ICON"
  rm -rf "$WORK"
fi

# 2. Compile.
echo "==> Compiling"
swift build -c release --arch arm64 2>&1 | grep -E "error:|warning:|Build complete" || true
BIN="$(swift build -c release --arch arm64 --show-bin-path)/Monobrow"
[ -x "$BIN" ] || { echo "build failed"; exit 1; }

# 3. Assemble the app bundle.
echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/ru.lproj"
cp "$BIN" "$APP/Contents/MacOS/Monobrow"
strip -x "$APP/Contents/MacOS/Monobrow"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"
# A Russian localisation folder makes system-provided texts (menus, dialogs) appear in Russian.
printf '"CFBundleDisplayName" = "Monobrow";\n"CFBundleName" = "Monobrow";\n' > "$APP/Contents/Resources/ru.lproj/InfoPlist.strings"

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

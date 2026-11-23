#!/bin/zsh
# Builds Islet.app into ./build.
#
#   ./build.sh             build for this Mac's chip
#   ./build.sh --run       build and launch it
#   ./build.sh --install   build, copy to /Applications and launch (needed for Launch at Login)
#   ./build.sh --release   universal build (Apple Silicon + Intel) and build/Islet.zip for GitHub releases
set -euo pipefail
cd "${0:A:h}"

MODE="${1:-}"
APP=build/Islet.app
BIN_NAME=Islet

if [[ "$MODE" == "--release" ]]; then
  # One app that runs natively on both Apple Silicon and Intel Macs.
  # Separate build folders, or the second architecture overwrites the first.
  for arch in arm64 x86_64; do
    swift build -c release --triple "$arch-apple-macosx15.0" --scratch-path ".build/$arch"
  done
  ARM_BIN="$(swift build -c release --triple arm64-apple-macosx15.0 --scratch-path .build/arm64 --show-bin-path)/$BIN_NAME"
  X86_BIN="$(swift build -c release --triple x86_64-apple-macosx15.0 --scratch-path .build/x86_64 --show-bin-path)/$BIN_NAME"
else
  swift build -c release
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
if [[ "$MODE" == "--release" ]]; then
  lipo -create "$ARM_BIN" "$X86_BIN" -output "$APP/Contents/MacOS/$BIN_NAME"
else
  cp "$(swift build -c release --show-bin-path)/$BIN_NAME" "$APP/Contents/MacOS/$BIN_NAME"
fi
cp Resources/Info.plist "$APP/Contents/Info.plist"

if [[ ! -f build/AppIcon.icns ]]; then
  rm -rf build/AppIcon.iconset
  swift Scripts/make-icon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature: enough for macOS to run it locally. (No paid Apple Developer ID, so it
# isn't notarized; install.sh downloads it in a way that doesn't trigger the quarantine prompt.)
codesign --force --sign - "$APP"
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/$BIN_NAME"))"

case "$MODE" in
  --run)
    pkill -x Islet 2>/dev/null || true
    open "$APP"
    ;;
  --install)
    pkill -x Islet 2>/dev/null || true
    sleep 0.5
    rm -rf /Applications/Islet.app
    ditto "$APP" /Applications/Islet.app
    echo "Installed /Applications/Islet.app"
    open /Applications/Islet.app
    ;;
  --release)
    rm -f build/Islet.zip
    ditto -c -k --keepParent "$APP" build/Islet.zip
    echo "Release archive: build/Islet.zip ($(du -h build/Islet.zip | cut -f1))"
    ;;
esac

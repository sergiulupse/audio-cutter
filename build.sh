#!/bin/bash
#
# build.sh  ::  compile Audio Cutter and assemble a double-clickable .app
#
# Swift Package Manager produces a bare Unix executable. macOS will not treat
# that as an app (no Dock icon, no menu bar, no window focus), so this script
# wraps it in the folder-with-a-plist that macOS calls an application bundle,
# gives it its icon, and ad-hoc signs it.
#
# Toolchain: this uses the full Xcode at /Applications/Xcode.app when it is
# there, regardless of what `xcode-select` currently points at, and falls back
# to the Command Line Tools only if Xcode is missing.
#
#   ./build.sh            release build, then open the app
#   ./build.sh debug      faster compile, no optimisation
#   ./build.sh --no-run   just build
#   ./build.sh --icon     redraw the icon from Resources/make-icon.swift first
#   ./build.sh --dmg      also package build/Audio-Cutter.dmg for distribution
#
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="release"
RUN=1
ICON=0
DMG=0
for arg in "$@"; do
  case "$arg" in
    debug)    CONFIG="debug" ;;
    release)  CONFIG="release" ;;
    --no-run) RUN=0 ;;
    --icon)   ICON=1 ;;
    --dmg)    DMG=1; RUN=0 ;;
  esac
done

APP_NAME="Audio Cutter"
BUNDLE_ID="com.audiocutter.app"
VERSION="0.2.0"
OUT="build/${APP_NAME}.app"

# Prefer the real Xcode toolchain over the Command Line Tools.
if [[ -d "/Applications/Xcode.app/Contents/Developer" ]]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
  XCODE_VERSION="$(/usr/bin/defaults read /Applications/Xcode.app/Contents/Info.plist CFBundleShortVersionString 2>/dev/null || echo "?")"
  echo "> Toolchain: Xcode ${XCODE_VERSION}"
else
  echo "> Toolchain: Command Line Tools (Xcode.app not found in /Applications)"
fi

if [[ "$ICON" == "1" || ! -f "Resources/AppIcon.icns" ]]; then
  echo "> Drawing the icon..."
  swift Resources/make-icon.swift
fi

echo "> Compiling (${CONFIG})..."
swift build -c "$CONFIG"

BIN="$(swift build -c "$CONFIG" --show-bin-path)/AudioCutter"
if [[ ! -f "$BIN" ]]; then
  echo "x Executable not found at $BIN"
  exit 1
fi

echo "> Assembling ${OUT}..."
rm -rf "$OUT"
mkdir -p "${OUT}/Contents/MacOS" "${OUT}/Contents/Resources"
cp "$BIN" "${OUT}/Contents/MacOS/AudioCutter"
cp "Resources/AppIcon.icns" "${OUT}/Contents/Resources/AppIcon.icns"

cat > "${OUT}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>       <string>${APP_NAME}</string>
    <key>CFBundleExecutable</key>        <string>AudioCutter</string>
    <key>CFBundleIdentifier</key>        <string>${BUNDLE_ID}</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key>           <string>${VERSION}</string>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
    <key>CFBundleIconName</key>          <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>    <string>14.0</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>NSPrincipalClass</key>          <string>NSApplication</string>
    <key>NSSupportsAutomaticTermination</key> <false/>
    <key>NSRequiresAquaSystemAppearance</key> <false/>

    <!-- So audio files can be opened with this app from Finder. -->
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Audio File</string>
            <key>CFBundleTypeRole</key><string>Editor</string>
            <key>CFBundleTypeIconFile</key><string>AppIcon</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.audio</string>
                <string>public.mp3</string>
                <string>com.microsoft.waveform-audio</string>
                <string>public.aiff-audio</string>
                <string>public.mpeg-4-audio</string>
                <string>org.xiph.flac</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

# Ad-hoc signature. Without it macOS nags on every launch and the app cannot
# keep its permissions between builds.
echo "> Signing (ad-hoc)..."
codesign --force --sign - --timestamp=none "$OUT" >/dev/null 2>&1 || \
  echo "  (codesign skipped)"

# Nudge Finder and the Dock to notice a changed icon, which they cache hard.
touch "$OUT"
/usr/bin/killall -q Dock 2>/dev/null || true

echo "= Built ${OUT}"

# Package a disk image for the Releases page. UDZO is the compressed read-only
# format every Mac can open by double-clicking. The symlink to /Applications is
# the drag-here-to-install convention.
if [[ "$DMG" == "1" ]]; then
  echo "> Packaging disk image..."
  STAGE="$(mktemp -d)"
  cp -R "$OUT" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  rm -f "build/Audio-Cutter.dmg"
  hdiutil create \
    -volname "${APP_NAME}" \
    -srcfolder "$STAGE" \
    -ov -format UDZO \
    -quiet \
    "build/Audio-Cutter.dmg"
  rm -rf "$STAGE"
  echo "= Packaged build/Audio-Cutter.dmg ($(du -h "build/Audio-Cutter.dmg" | cut -f1))"
fi

if [[ "$RUN" == "1" ]]; then
  echo "> Launching..."
  open "$OUT"
fi

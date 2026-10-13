#!/bin/zsh
# Builds Encore.app with swiftc directly (SwiftPM in the Command Line Tools is broken here).
# Needs: Command Line Tools, `brew install mpv`.
set -euo pipefail
cd "${0:A:h}/.."
# Use the Command Line Tools even when Xcode is installed and selected (Xcode's
# toolchain refuses to run until its license is accepted, and isn't needed here).
export DEVELOPER_DIR=/Library/Developer/CommandLineTools

CONFIG=${1:-release}
VERSION=$(cat VERSION) # bumped by scripts/release.sh
OUT=build.nosync # ".nosync": iCloud Drive leaves it alone (it was making "Encore 2.app" copies)
# Build and sign outside Documents: iCloud/Finder keep adding extended attributes
# there, which codesign rejects. The signed bundle is copied in at the end.
STAGE=$(mktemp -d -t encore-build)
APP=$STAGE/Encore.app
OPT=$([[ $CONFIG == debug ]] && echo "-Onone -g" || echo "-O")

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -swift-version 5 -target arm64-apple-macosx14.0 -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk -parse-as-library ${=OPT} \
  -suppress-warnings \
  -I Sources/CMpv -I Sources/CFFmpeg -Xcc -I/opt/homebrew/include -L /opt/homebrew/lib -lmpv -lavformat -lavcodec -lswscale -lavutil -framework OpenGL \
  $(find Sources/Encore -name '*.swift') \
  -o "$APP/Contents/MacOS/Encore"

# App icon, drawn by scripts/make-icon.swift.
swiftc -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk -suppress-warnings scripts/make-icon.swift -o "$STAGE/make-icon"
"$STAGE/make-icon" "$STAGE/AppIcon.iconset" >/dev/null
iconutil -c icns "$STAGE/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Encore</string>
  <key>CFBundleDisplayName</key><string>Encore</string>
  <key>CFBundleIdentifier</key><string>local.encore.player</string>
  <key>CFBundleExecutable</key><string>Encore</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.entertainment</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/></dict>
</dict></plist>
PLIST

xattr -cr "$APP"
codesign --force --sign - "$APP"
mkdir -p "$OUT"
rm -rf "$OUT/Encore.app"
ditto "$APP" "$OUT/Encore.app"
rm -rf "$STAGE"
touch "$OUT/Encore.app" # nudges Finder/Dock to pick up a changed icon
codesign --verify "$OUT/Encore.app" 2>/dev/null || echo "note: signature check failed after copy; the app still runs locally"
echo "Built $OUT/Encore.app"

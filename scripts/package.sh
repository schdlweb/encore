#!/bin/zsh
# Builds a self-contained Encore.app (libmpv and all its libraries inside) and zips it
# for sending to someone else. Output: build.nosync/Encore.zip
# The recipient needs an Apple Silicon Mac on the same macOS version the Homebrew
# libraries were built for (see README), but no Homebrew.
set -euo pipefail
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
cd "${0:A:h}/.."

./scripts/build.sh release

STAGE=$(mktemp -d -t encore-package)
ditto build.nosync/Encore.app "$STAGE/Encore.app"
python3 -I scripts/bundle-dylibs.py "$STAGE/Encore.app"

# The Homebrew libraries only load on the macOS they were built for (or later). Say so in
# the app, so an older Mac gets Finder's "needs macOS N or later" rather than a crash at
# launch with a missing-symbol report.
MINOS=$(for lib in "$STAGE/Encore.app/Contents/Frameworks/"*.dylib; do
  otool -l "$lib" | awk '/LC_BUILD_VERSION/ {b=1} b && $1 == "minos" {print $2; b=0}'
done | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)
# Only the major version: Homebrew builds a library for the macOS it was bottled on
# (27.0, or 27.2 for one rebuilt since), but a library built on 27.2 still loads on 27.0.
# Requiring the exact point release would lock out Macs the app runs fine on.
[[ -n $MINOS ]] && MINOS="${MINOS%%.*}.0"
if [[ -n $MINOS ]]; then
  /usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion $MINOS" "$STAGE/Encore.app/Contents/Info.plist"
  echo "Bundled libraries need macOS $MINOS or later"
fi

# install_name_tool invalidates signatures: sign each library, then the app.
xattr -cr "$STAGE/Encore.app"
for lib in "$STAGE/Encore.app/Contents/Frameworks/"*.dylib; do
  codesign --force --sign - "$lib" 2>/dev/null
done
codesign --force --sign - "$STAGE/Encore.app"
codesign --verify --deep --strict "$STAGE/Encore.app"

rm -rf build.nosync/Encore-share.app build.nosync/Encore.zip
ditto "$STAGE/Encore.app" build.nosync/Encore-share.app
ditto -c -k --keepParent --norsrc "$STAGE/Encore.app" build.nosync/Encore.zip
rm -rf "$STAGE"
echo "Packaged build.nosync/Encore.zip ($(du -h build.nosync/Encore.zip | cut -f1))"

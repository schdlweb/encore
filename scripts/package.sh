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

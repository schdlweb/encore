#!/bin/zsh
# Builds and runs the checks in Tests/ (stream ranking, file-name reading, the on-disk
# stores, the updater's version and checksum logic). No network, and nothing of yours is
# touched: the stores are pointed at a temporary folder.
#
# Like build.sh this calls swiftc directly: every source file except the app's entry
# point, plus Tests/main.swift, as one small command-line program.
set -euo pipefail
cd "${0:A:h}/.."
export DEVELOPER_DIR=/Library/Developer/CommandLineTools

STAGE=$(mktemp -d -t encore-tests)
trap 'rm -rf "$STAGE"' EXIT

swiftc -swift-version 5 -target arm64-apple-macosx14.0 -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk -Onone \
  -Xcc -DGL_SILENCE_DEPRECATION \
  -I Sources/CMpv -I Sources/CFFmpeg -Xcc -I/opt/homebrew/include -L /opt/homebrew/lib -lmpv -lavformat -lavcodec -lswscale -lavutil -framework OpenGL \
  $(find Sources/Encore -name '*.swift' ! -name 'EncoreApp.swift') Tests/main.swift \
  -o "$STAGE/encore-tests" 2> >(grep -v '^ld: warning: building for macOS' >&2)

"$STAGE/encore-tests"

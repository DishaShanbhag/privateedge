#!/bin/sh
# Download the llama.cpp XCFramework the app links against, and check its SHA-256.
# b12387 is the llama.cpp commit (a956a852) vendored by llama-cpp-python 0.3.37, the version the
# Mac harness uses, so the phone and the Mac run the same inference code.
set -eu
TAG=b12387
SHA=93d4ab674c75d590b6e0650b24683964c61dbbeb6bb94aa8dbed5a61346899f8
DEST="$(cd "$(dirname "$0")" && pwd)/PrivateEdgeCore/Frameworks"
ZIP="$(mktemp -d)/llama-$TAG-xcframework.zip"
curl -sSfL -o "$ZIP" "https://github.com/ggml-org/llama.cpp/releases/download/$TAG/llama-$TAG-xcframework.zip"
echo "$SHA  $ZIP" | shasum -a 256 -c -
mkdir -p "$DEST" && rm -rf "$DEST/llama.xcframework"
unzip -q "$ZIP" -d "$(dirname "$ZIP")"
mv "$(dirname "$ZIP")/build-apple/llama.xcframework" "$DEST/"
echo "llama.xcframework ($TAG) is in $DEST"

#!/usr/bin/env bash
# Builds ios/vendor/llama.xcframework (iPhone + iPhone Simulator) from llama.cpp release b12387,
# the exact commit llama-cpp-python 0.3.37 vendors (a956a852c), so the phone runs the same
# llama.cpp code as the Mac harness. The official release zip has no simulator slice.
#
# Needs: full Xcode (not just Command Line Tools) and cmake (brew install cmake).
#   ios/scripts/build_llama.sh          # about 5-10 minutes
set -euo pipefail

TAG=b12387
SHA=a956a852c9c8bc1fb07206364838ddef299178c0
HERE="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$HERE/vendor"
SRC="$VENDOR/llama.cpp-$TAG"

if ! xcodebuild -version >/dev/null 2>&1; then
  echo "Xcode is not selected. Install Xcode, open it once, then run:"
  echo "  sudo xcode-select -s /Applications/Xcode.app"
  exit 1
fi
command -v cmake >/dev/null || { echo "cmake missing: brew install cmake"; exit 1; }

mkdir -p "$VENDOR"
if [ ! -d "$SRC" ]; then
  echo "Downloading llama.cpp $TAG source..."
  curl -sL -o "$VENDOR/src-$TAG.tar.gz" "https://github.com/ggml-org/llama.cpp/archive/refs/tags/$TAG.tar.gz"
  tar xzf "$VENDOR/src-$TAG.tar.gz" -C "$VENDOR"
fi
echo "llama.cpp $TAG ($SHA)" > "$VENDOR/LLAMA_VERSION"

cd "$SRC"
rm -rf build-apple build-ios-sim build-ios-device
./build-xcframework.sh ios-sim ios-device
rm -rf "$VENDOR/llama.xcframework"
cp -R build-apple/llama.xcframework "$VENDOR/llama.xcframework"
echo
echo "Built $VENDOR/llama.xcframework:"
ls "$VENDOR/llama.xcframework"

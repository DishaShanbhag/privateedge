#!/usr/bin/env bash
# Generates ios/PrivateEdge/PrivateEdge.xcodeproj from project.yml (XcodeGen).
#   ios/scripts/make_project.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
command -v xcodegen >/dev/null || { echo "xcodegen missing: brew install xcodegen"; exit 1; }
[ -d "$HERE/PrivateEdgeCore/Frameworks/llama.xcframework/ios-arm64_x86_64-simulator" ] || [ -d "$HERE/PrivateEdgeCore/Frameworks/llama.xcframework/ios-arm64-simulator" ] || {
  echo "Build llama.cpp with a Simulator slice first: ios/scripts/build_llama.sh"; exit 1; }
if [ ! -f "$HERE/Bundle/manifest.json" ]; then
  echo "Exporting the run bundle (harness/export_ios_bundle.py)..."
  (cd "$ROOT" && python harness/export_ios_bundle.py)
fi
[ -f "$ROOT/models/embed/bge-small-en-v1.5-q8_0.gguf" ] || {
  echo "Missing models/embed/bge-small-en-v1.5-q8_0.gguf (C2 notes). See ios/README.md."; exit 1; }

SPEC="$HERE/PrivateEdge/project.yml"
if [ ! -f "$ROOT/models/Llama-3.2-3B-Instruct-Q4_K_M.gguf" ]; then
  echo "Note: models/Llama-3.2-3B-Instruct-Q4_K_M.gguf not found; building the app without it."
  echo "      Copy it into the app with the Files app or Finder later (Model tab explains)."
  SPEC="$HERE/PrivateEdge/.project.nomodel.yml"
  grep -v "Llama-3.2-3B-Instruct-Q4_K_M.gguf" "$HERE/PrivateEdge/project.yml" \
    | awk 'BEGIN{skip=0} /# The 2 GB weights/{skip=1; next} skip==1 && /buildPhase: resources/{skip=0; next} {print}' > "$SPEC"
fi
cd "$HERE/PrivateEdge"
xcodegen generate --spec "$SPEC" --project "$HERE/PrivateEdge"
echo "Open: open $HERE/PrivateEdge/PrivateEdge.xcodeproj"

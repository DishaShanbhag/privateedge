#!/usr/bin/env bash
# Generates ios/PrivateEdge/PrivateEdge.xcodeproj from project.yml (XcodeGen).
#   ios/scripts/make_project.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
command -v xcodegen >/dev/null || { echo "xcodegen missing: brew install xcodegen"; exit 1; }
[ -d "$HERE/vendor/llama.xcframework" ] || { echo "Build llama.cpp first: ios/scripts/build_llama.sh"; exit 1; }

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

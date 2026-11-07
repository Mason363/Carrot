#!/bin/zsh
# Xcode build phase: Carrot runs on Apple silicon only, so drop other architectures from
# embedded frameworks (llama.cpp ships universal binaries) and re-sign them.
set -euo pipefail
FRAMEWORKS="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}"
[[ -d "$FRAMEWORKS" ]] || exit 0
IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
TIMESTAMP="--timestamp=none"
[[ "${CONFIGURATION}" == "Release" ]] && TIMESTAMP="--timestamp"
for framework in "$FRAMEWORKS"/*.framework(N); do
  name="${framework:t:r}"
  binary="$framework/Versions/A/$name"
  [[ -f "$binary" ]] || continue
  if lipo -archs "$binary" | grep -q x86_64; then
    lipo -thin arm64 "$binary" -output "$binary.thin"
    mv "$binary.thin" "$binary"
    codesign --force --sign "$IDENTITY" --options runtime $TIMESTAMP "$framework"
  fi
done

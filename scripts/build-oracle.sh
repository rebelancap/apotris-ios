#!/usr/bin/env bash
# Build the macOS oracle (ground truth) from the overlay-composed work tree.
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/apply-overlay.sh

cd work/apotris
if [ ! -f build-macos/build.ninja ]; then
  meson setup build-macos \
    -Dsdl2_mixer:opus=disabled \
    -Dsdl2_mixer:flac=disabled \
    -Dsdl2_mixer:mpg123=disabled
fi
meson compile -C build-macos
echo "oracle OK: $PWD/build-macos/Apotris"

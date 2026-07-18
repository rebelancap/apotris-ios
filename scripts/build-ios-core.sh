#!/usr/bin/env bash
# Cross-build the Apotris core (game + Tilengine + SoLoud + openmpt + deps)
# as static libraries for an Apple mobile platform, then merge them into one
# libapotris.a for the app shell to link.
#
# Usage: scripts/build-ios-core.sh [ios-sim|ios|xros-sim|xros]
set -euo pipefail
cd "$(dirname "$0")/.."

PLATFORM="${1:-ios-sim}"
case "$PLATFORM" in
  ios-sim|ios|xros-sim|xros) ;;
  *) echo "error: unknown platform '$PLATFORM' (want ios-sim|ios|xros-sim|xros)" >&2; exit 1 ;;
esac

scripts/apply-overlay.sh

# Build dir is named by Xcode platform so the app project can reference
# build-core-$(PLATFORM_NAME) uniformly.
case "$PLATFORM" in
  ios-sim)  XCPLAT=iphonesimulator ;;
  ios)      XCPLAT=iphoneos ;;
  xros-sim) XCPLAT=xrsimulator ;;
  xros)     XCPLAT=xros ;;
esac

cd work/apotris
BUILD="build-core-$XCPLAT"

if [ ! -f "$BUILD/build.ninja" ]; then
  meson setup "$BUILD" --cross-file "meson/$PLATFORM.ini"
fi
meson compile -C "$BUILD"

# Merge every produced static lib into one archive for the app shell.
LIBS=$(find "$BUILD" -name '*.a' | sort)
[ -n "$LIBS" ] || { echo "error: no static libs produced" >&2; exit 1; }
echo "$LIBS" | sed 's/^/  merging /'
libtool -static -o "$BUILD/libapotris.a" $LIBS 2> >(grep -v 'has no symbols' >&2 || true)
echo "core OK: work/apotris/$BUILD/libapotris.a ($(du -h "$BUILD/libapotris.a" | cut -f1 | tr -d ' '))"

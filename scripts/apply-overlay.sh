#!/usr/bin/env bash
# Compose vendor/apotris + overlay -> work/apotris. Loud failures (charter rule 3).
#
# work/apotris is a disposable plain tree (no git): rsync mirror of vendor
# (submodules included, .git excluded), with build dirs and subproject extras
# (extracted wraps, packagecache) protected from deletion. Patches apply with
# patch --fuzz=0; any reject fails the build.
set -euo pipefail
cd "$(dirname "$0")/.."
PIN=$(cat upstream.pin)

[ -d vendor/apotris ] || { echo "error: vendor/apotris missing — run scripts/bootstrap.sh" >&2; exit 1; }

ACTUAL=$(git -C vendor/apotris rev-parse HEAD)
if [ "$ACTUAL" != "$PIN" ]; then
  echo "error: vendor/apotris at $ACTUAL but upstream.pin says $PIN — run scripts/bootstrap.sh" >&2
  exit 1
fi

mkdir -p work
rsync -a --delete \
  --exclude='.git' \
  --filter='P /build-*' \
  --filter='P /subprojects/*' \
  vendor/apotris/ work/apotris/

npatch=0
for p in overlay/patches/*.patch; do
  [ -e "$p" ] || break
  echo "patch: $p"
  patch --batch --fuzz=0 -p1 -d work/apotris < "$p"
  npatch=$((npatch + 1))
done

nadd=0
if [ -d overlay/add ] && [ -n "$(find overlay/add -type f -print -quit 2>/dev/null)" ]; then
  rsync -a overlay/add/ work/apotris/
  nadd=$(find overlay/add -type f | wc -l | tr -d ' ')
fi

echo "overlay OK: work/apotris @ ${PIN:0:9} + ${npatch} patches + ${nadd} added files"

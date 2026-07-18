#!/usr/bin/env bash
# Reconstruct vendor/apotris from nothing, pinned to upstream.pin.
set -euo pipefail
cd "$(dirname "$0")/.."
PIN=$(cat upstream.pin)

if [ ! -d vendor/apotris/.git ]; then
  mkdir -p vendor
  git clone https://gitea.com/akouzoukos/apotris.git vendor/apotris
fi

cd vendor/apotris
git fetch --quiet origin || echo "warn: fetch failed (offline?); using local objects"
git checkout --quiet --detach "$PIN"
git submodule update --init
cd ../..

echo "bootstrap OK: vendor/apotris @ $PIN"

# Installing Apotris on Apple Vision Pro

This is a native iOS and visionOS port of [Apotris](https://apotris.com) by akouzoukos, a free and open block-stacking game: the game's own engine (the Tilengine renderer and SoLoud audio) rebuilt for Apple platforms and presented through Metal. It is not an emulator. On Apple Vision Pro it runs in a crisp, freely resizable window.

## What you need

- Apple Vision Pro on visionOS 2 or later
- For the prebuilt app: SideStore on the headset, installed with [iloader](https://github.com/rebelancap/iloader/releases#release-visionos)
- To build from source: macOS with Xcode, plus `meson`, `ninja` and `xcodegen` (`brew install meson ninja xcodegen`)

## Your game files

None. Apotris is fully free and open: the app is complete, and there's nothing extra to add.

## Install the prebuilt app

1. Install SideStore on the headset with [iloader](https://github.com/rebelancap/iloader/releases#release-visionos). SideStore and AltStore can't be installed on visionOS the usual way; iloader is what gets SideStore there. No Xcode or Dev Strap required.
2. In SideStore, go to *Sources → +* and paste this source, then install Apotris:

   ```
   https://raw.githubusercontent.com/rebelancap/apotris-ios/main/sidestore/apps-visionos.json
   ```

   Apotris updates from this source when new versions ship.

To install by hand instead, download `Apotris-*-visionOS.ipa` from the [latest release](https://github.com/rebelancap/apotris-ios/releases/latest) and install it through SideStore or AltStore.

## Build from source

From a checkout of this repo:

```sh
scripts/bootstrap.sh                # clone + pin upstream Apotris into vendor/
scripts/build-ios-core.sh xros      # cross-build the core for Apple Vision Pro
cd app && xcodegen generate         # -> app/Apotris.xcodeproj
```

Then open `app/Apotris.xcodeproj` in Xcode, choose the `ApotrisVision` scheme, set your own development team (`app/project.yml` sets the maintainer's), and build and run to your Apple Vision Pro. For the Vision Pro Simulator, build the core with `scripts/build-ios-core.sh xros-sim`.

Upstream Apotris is vendored unmodified and pinned by commit; every local change is a small `#ifdef IOS`-gated patch in `overlay/patches/`. The iOS Simulator build and the upstream-update process are in [Building from source](README.md#building-from-source) and [`docs/updating.md`](docs/updating.md).

## Controls on Apple Vision Pro

- Pinch-tap with your right hand to rotate clockwise, your left hand to rotate counter-clockwise.
- Pinch-drag to move and soft-drop; flick to hard-drop.
- A bottom ornament has pause, hold and rotate for eye-and-pinch play.
- Game controllers and hardware keyboards work everywhere, through the game's own remappable bindings.

## Notes

- Online Multi Battle (private rooms by code, up to 5 players) uses the same signalling server as the official Apotris builds. Peers connect directly, so both ends need a reachable network path.
- Apps sideloaded with a free Apple account expire after 7 days (paid developer accounts last a year). SideStore refreshes them in the background; if the app stops launching, open SideStore and let it re-sign.
- Licensed under the GNU AGPL v3 (see [`COPYING`](COPYING)), matching upstream Apotris.

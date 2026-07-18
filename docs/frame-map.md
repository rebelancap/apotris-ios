# Frame Map — Apotris non-GBA ("TE") platform core

One page: how input becomes pixels and sound each frame, and where `liba_ios` slots in. Line refs against upstream pin (v4.1.0-333-g5836fa9).

## The loop (shared, main.cpp:182)

```
main()
  platformInit()            liba_pc.cpp:113  TLN_Init(512,512,4layers,128spr) → framebuffer=malloc(512*512*4)
                            TLN_SetRenderTarget(framebuffer, 2048); raster+blend callbacks; windowInit()  ← backend hook
                            new LinkUniversal(); new MultiplayerLink(...)   (WebRTC-less under NO_ONLINE)
  loadSave() → initialize() → changeScene(TitleScene)
  while (closed()) {        closed() = backend liveness + songEndHandler() + rumblePatternLoop()
    checkSceneSwitch()      menuSystem.cpp:35  (delete scene; scene = factory(); init)
    vsync()                 liba_pc.cpp:231 — see below
    scene->update()         scene logic; calls key_poll()+control(); may nest its own while(){vsync()} loops
  }
```

**vsync() (liba_pc.cpp:231):** `onVBlank()` (scene->draw() when canDraw, frameCounter++) → `TLN_UpdateFrame(0)` rasterizes layers+sprites into the 512×512 RGBA framebuffer (byte order R,G,B,A; pitch 2048) → **`updateWindow(framebuffer)`** ← the backend present hook.

**updateWindow (backend-owned) must synchronously:** present the framebuffer (crop rows `rowStart..rowEnd`, scale `windowScale`), pump input (`handleInput()`), pace to 60 (nanotime_step; mach path exists). **Synchronous is a hard constraint**: the game calls `vsync()` re-entrantly from nested blocking loops (fades, name entry, end screens) — presentation cannot be decoupled from this call.

## liba_ios plan on that seam

- Game runs on a dedicated thread (`main()` moved to `apotris_main()`); UIKit/SwiftUI owns the real main thread.
- `updateWindow`: copy framebuffer → MTLTexture (RGBA8Unorm, 512×512, bytesPerRow 2048) → encode textured-quad blit to CAMetalLayer drawable (nearest) → present → drain UI-thread input queue into key state → snapshot swap → block on CADisplayLink-signaled semaphore (60 Hz pacing, ProMotion-safe).
- `refreshWindowSize` math copied from liba_window.cpp:407 — the *game* reads `windowScale/rowStart/rowEnd` to lay out content for the visible row window, so the backend must maintain them identically.

## Input (backend-owned state, queried by game)

```
currentlyPressed / currentKeys / previousKeys : unordered_set<uint32_t>   lastInputType : KEYBOARD|CONTROLLER|TOUCH
pressKey(k,type) / unpressKey(k,type)   →  mutate currentlyPressed
handleInput() end-of-frame:  previousKeys = currentKeys; currentKeys = currentlyPressed
key_is_down / key_hit / key_released / key_first / keys_raw  (bodies copyable from liba_window.cpp:225-291)
```

Packed binding encoding (must match exactly, savefile-compatible): `key = (SDL_CONTROLLER_BUTTON_x << 16) | packKey(SDLK_x)`; `splitKey()` picks the half by `lastInputType`. Analog stick dirs are synthetic keys `(1<<14)|axis|(dir<<5)`. We vendor the SDL keycode/button *enum values* in a shim header — no SDL runtime.

Gameplay wiring is entirely engine-side (`GameScene::control()` game.cpp:1309: `key_hit(savefile->settings.keys.moveLeft) → game->keyLeft(1)` etc.) — a backend only feeds key state. Gestures therefore synthesize presses of the *currently bound* keys read from `savefile->settings.keys/menuKeys`.

**Gameplay vs menu for gesture semantics:** `dynamic_cast<GameScene*>(scene) && !paused` (globals `scene` main.cpp:83, `paused` main.cpp:58; GameScene is the single gameplay scene for every mode). Everything else — including the pause menu — gets menu semantics. Backend exposes this as `apotris_in_gameplay()` for the shell.

## Audio (pure SoLoud — SDL2_mixer is linked upstream but never called)

`liba_sdl_audio.cpp`: `gSoloud.init()` (auto backend) · sfx = `SoLoud::Wav` from assets/*.wav (`sfx(n)` → play) · music = `SoLoud::Queue` of `WavStream` (wav/ogg) or `SoLoud::Openmpt` (.mod/.it via libopenmpt) · `startSong/stopSong/setMusicVolume/setMusicTempo` implemented there; `songEndHandler()` cycles playlist from `closed()`.
iOS: build SoLoud with its vendored **coreaudio** backend (AudioQueue — present on iOS and visionOS), patch the two `SDL_RWFromFile` read sites to stdio, point asset root at the app bundle.

## Saves

Fixed 32 KiB binary block `Apotris.sav` (write path liba_window.cpp:568). iOS backend: `savefileDir()` → `<container>/Documents/Apotris` (the platform.hpp `__APPLE__` externs `homeDir/savefileDir` are satisfied by liba_ios). Same file format as desktop — savefiles are portable across our oracle and the port.

## Networking (v1: compiled out)

Online play = LinkUniversal over libdatachannel WebSocket+DataChannels (LinkWebRTC.hpp), guarded `#ifndef SWITCH` in exactly 3 places; update-check = cpr in liba_window (PC-only, not compiled for iOS). NO_ONLINE patch widens those 3 guards; dep graph then needs no libdatachannel/cpr/openssl — the Switch build ships this exact shape.

## What compiles for iOS (defines: `TE`, `IOS`, `NO_ONLINE`; **no** `PC`, no `GL`, no SDL)

Reused unchanged: liba_pc.cpp (TE core), liba_sdl_audio.cpp (minus RWops), all game/scene/blockEngine/menus/music/rumblePatterns/text/sprites, nanotime, stb, Tilengine, SoLoud(+openmpt), nlohmann_json.
New: liba_ios.mm/.h (windowInit, updateWindow→Metal, input state, saves, rumble→CoreHaptics, battery→UIDevice, lifecycle), SDL-enum shim header.
Skipped: liba_window/android/switch/web/n3ds/gba (self-gated), shader.cpp (GL), sfMod.cpp (not in build), vgm.cpp (GBA-only), cpr, libdatachannel, SDL2, SDL2_mixer.

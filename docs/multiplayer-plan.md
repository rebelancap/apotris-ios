# Plan: bringing Apotris online multiplayer to iOS + visionOS

Status: **not started.** Online play is compiled out of v1 (D-004) behind a
`NO_ONLINE` flag. This doc is the implementation plan to turn it on. It's
written to be executable by whoever picks it up (this session, a fresh chat, or
a dedicated agent) — every claim below is verified against the actual source.

## TL;DR

- **Less code work than it looks.** The online transport is one header-only
  class (`LinkUniversal` in `include/LinkWebRTC.hpp`); `NO_ONLINE` just swaps it
  for a no-op stub. The game already `new`s it unconditionally and every scene
  already compiles against the stub. Re-enabling is ~a handful of `meson.build`
  lines, not a code rewrite.
- **The real work is cross-building the WebRTC dependency stack** for the 4
  Apple targets (ios / ios-sim / xros / xros-sim).
- **The one decision that de-risks everything:** use **mbedTLS**, not OpenSSL,
  as libdatachannel's crypto backend.
- **The biggest risk isn't the build — it's TURN.** Only public STUN is
  configured; pure STUN peer-to-peer routinely fails on cellular / symmetric
  NAT. We'll need a TURN server. That's infra, and it needs Austin.

## How it works (so the plan makes sense)

WebRTC **DataChannels carry gameplay peer-to-peer** (2-byte move packets + a
44-byte full-board snapshot every 16 frames); a single **WebSocket carries only
signaling** (SDP offer/answer, ICE candidates, matchmaking, and a shared RNG
seed) to the official server. The signaling server never sees gameplay.

- Client endpoint is **hardcoded** at `include/LinkWebRTC.hpp:341`:
  `wss://api.apotris.com/ws/<localId>/<roomId-or-"match">`, STUN at
  `stun:stun.l.google.com:19302` (`:58`). The official server is Internet-
  reachable, so no server change is strictly required to ship.
- API the game calls: set global `roomId` (`""` = server matchmaking, non-empty
  = named private room) → `multiplayerLink->activate()`; send via
  `sendEvent()` / `broadcastState()`; receive via `readPackets()`; stop via
  `deactivate(true)`. Scenes: `MatchMakingScene` (lobby) → `MultBattleScene`
  (mode `BATTLE`, "Multi Battle").

## What's already done for us

- `linkUniversal` / `multiplayerLink` are `new`'d **unconditionally**
  (`source/liba_pc.cpp:149-150`) and work against the stub — **nothing to
  restore there.**
- Tilengine's OpenSSL use is already gone (overlay patch 0007 → bundled MD5), so
  **libdatachannel becomes the only crypto consumer** in the build.
- `scripts/build-ios-core.sh` merges every produced `*.a` into `libapotris.a`
  via a glob, so new online libs are linked automatically once they build.

## Dependencies to cross-build (the whole list)

| Dep | Role | Difficulty (Apple cross) |
|---|---|---|
| nlohmann_json | signaling JSON (header-only) | trivial (already building) |
| plog | libdatachannel logging (header-only) | trivial |
| usrsctp | userland SCTP inside the DataChannel | easy — its meson already handles `ios`; inet/inet6 off = no real sockets |
| libdatachannel 0.20.2 | WebRTC DataChannels + WebSocket (C++20 meson) | medium — trims cleanly with `RTC_ENABLE_MEDIA=0` |
| libjuice | ICE/STUN/TURN (C, CMake-in-meson) | medium-hard — CMake iOS cross is the classic snag; fallback = hand-write a small meson build |
| **mbedTLS** *(instead of OpenSSL)* | DTLS + `wss://` TLS | medium — pure C, crosses far easier than OpenSSL |

**Not needed** (confirmed unreferenced on the online path): cpr, libcurl,
libsrtp2 (`RTC_ENABLE_MEDIA=0`), protobuf, abseil, libsodium.

## Phases

### Phase 1 — Flip online back on (build plumbing)
- In `overlay/patches/0001-meson-apple-mobile.patch`: for `apple_mobile`, stop
  excluding `libdatachannel`, and **don't** define `-DNO_ONLINE`. (Leaving the
  `&& !defined(NO_ONLINE)` guards in `LinkWebRTC.hpp` is harmless once the define
  is gone; patch 0003 can stay.)
- Regenerate patches (`scripts/gen-patches.py`) and confirm the core still
  configures. It will now fail to *link* until the deps build — expected.

### Phase 2 — Cross-build the stack (the bulk of the work)
- **Decide mbedTLS:** patch `subprojects/libdatachannel/meson.build:26-31` so
  `apple_mobile` takes the `-DUSE_MBEDTLS=1` branch instead of OpenSSL. This is
  the highest-leverage change in the effort — it removes the single hardest
  dependency.
- Add mbedTLS as a meson subproject/wrap; cross-build for all 4 targets.
- Build usrsctp (easy), libjuice (watch the CMake-in-meson bridge on the xros
  SDKs — if it fights, wrap libjuice by hand: it's a compact C lib), then
  libdatachannel on top.
- Verify `libapotris.a` links with no undefined `rtc::` symbols.

### Phase 3 — iOS wiring (small but mandatory — easy to miss)
- **CA cert:** the generic desktop path creates `rtc::WebSocket` with no cert
  file, so `wss://` validation will fail on iOS. Mirror the Android branch
  (`LinkWebRTC.hpp:140-164`) and pass the already-bundled
  `assets/ssl/cacert.pem` as `caCertificatePemFile`. **Without this, connect
  fails.**
- **Threading:** `activate()` blocks on a `std::future` until the socket opens
  (`:350`). Ensure it runs on a background thread, never main/render.
- **Info.plist:** add `NSLocalNetworkUsageDescription` to `app/Info.plist` and
  `app/Info-vision.plist` (same-Wi-Fi ICE candidates trigger the iOS Local
  Network prompt). No entitlement, no background mode needed.

### Phase 4 — TURN (the real risk, needs Austin)
Only public STUN is configured. On cellular CGNAT and symmetric-NAT Wi-Fi,
STUN-only P2P DataChannels frequently fail to connect. Options:
- Stand up a TURN server (coturn is the standard; a small VPS, or Austin's
  existing infra), add it to `config.iceServers` next to the STUN entry.
- Or coordinate with akouzoukos on whether the official Apotris service already
  operates a TURN relay we should point at.
Treat provisioning TURN as a first-class task, not a footnote — no amount of
cross-compiling fixes a connectivity failure.

### Phase 5 — Verification
- **Loopback/dev:** run the Deno signaling server locally (`server/`, port 8088)
  and point a debug build's URL literal at it.
- **Two physical devices** for the real test (matchmaking needs two clients;
  simulators can't reliably do ICE/DTLS to each other and the Local Network
  prompt only appears on device). Ideally one on Wi-Fi + one on cellular to
  prove NAT traversal — this is also how you prove whether TURN is required.
- Confirm the `activate()` future resolves off the main thread on visionOS.

## Risk ranking

1. **TURN / NAT traversal** (runtime) — most likely reason "it built but two
   phones won't connect." Plan for a relay.
2. **OpenSSL cross-build** — avoided entirely by choosing mbedTLS. If for some
   reason mbedTLS is rejected, this becomes a multi-day blocker.
3. **libjuice CMake-in-meson** on the visionOS SDKs — have the hand-wrapped-meson
   fallback ready.

## Open questions for Austin

- **TURN:** host our own (coturn on a VPS), or is there an official Apotris relay
  to use? This gates whether cross-network play works at all.
- **Server:** OK to connect to `wss://api.apotris.com` (akouzoukos's server), or
  do we self-host signaling? Worth a heads-up to akouzoukos either way since our
  clients would join their matchmaking pool.
- **Scope:** just get "Multi Battle" connecting two players first, or the full
  5-player rooms + reconnect UI in one pass?

## Executing this

The build work (Phases 1-3, 5) is self-contained and a good fit for a focused
run — a fresh chat pointed at this doc, or a dedicated agent, keeps it isolated
from the main port work. Phase 4 (TURN) needs Austin's infra decision before
cross-network play can be verified, so that's the natural sync point. Suggested
order: land Phases 1-3 and prove local loopback + same-Wi-Fi play first (no TURN
needed there), then decide TURN, then prove cross-network.

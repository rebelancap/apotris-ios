#pragma once
// Single-slot suspend-save for an in-progress game (iOS/visionOS port).
//
// Upstream persists settings, scoreboards and stats (save.h) but nothing about
// a live run: force-quitting mid-marathon loses it. This captures the whole
// BlockEngine::Game plus the Options that produced it into a versioned blob,
// and restores it by re-running startGame() (so upstream owns all the mode,
// music and tuning setup) and then overwriting the engine state on top.
//
// Deliberately one slot, and consumed on load: a snapshot that survived being
// resumed would let you reload after topping out and re-roll a leaderboard
// entry. Writing the blob to disk is the platform's job — see liba_ios.mm.
//
// The blob is little-endian host layout and never leaves the device.

#include <cstdint>
#include <vector>

namespace GameState {

// Summary carried in the blob header, so the menu can label "Continue"
// without paying to deserialize (or trust) the whole snapshot.
struct Info {
    int32_t mode = 0;
    int32_t subMode = 0;
    int32_t score = 0;
    int32_t level = 0;
    int32_t lines = 0;
    int32_t inGameTimer = 0;
};

// True when the live game is a snapshot-able single-player run: excludes the
// title attract demo, replay playback, multiplayer and CPU Battle (which owns
// a second Game), and finished games.
bool eligible();

// Serialize the live game. Returns an empty vector when !eligible().
std::vector<uint8_t> capture();

// Validate magic/version/checksum and read the header summary. Cheap; does
// not touch engine state.
bool inspect(const std::vector<uint8_t>& blob, Info& info);

// Rebuild the game from a blob. On success the caller enters GameScene
// (gameLoop()). Returns false — leaving engine state untouched — if the blob
// fails inspect().
bool restore(const std::vector<uint8_t>& blob);

} // namespace GameState

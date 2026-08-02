#pragma once
// C bridge between the Swift shell and the Apotris core (liba_ios.mm).
// Doubles as the Swift bridging header — keep it C-clean.

#include <stdbool.h>
#include <stdint.h>

#ifdef __OBJC__
#import "ApotrisMetalView.h"
#endif

typedef enum {
    ApotrisActionMoveLeft = 0,
    ApotrisActionMoveRight = 1,
    ApotrisActionRotateCW = 2,
    ApotrisActionRotateCCW = 3,
    ApotrisActionRotate180 = 4,
    ApotrisActionSoftDrop = 5,
    ApotrisActionHardDrop = 6,
    ApotrisActionHold = 7,
    ApotrisActionZone = 8,
    ApotrisActionMenuUp = 9,
    ApotrisActionMenuDown = 10,
    ApotrisActionMenuLeft = 11,
    ApotrisActionMenuRight = 12,
    ApotrisActionConfirm = 13,
    ApotrisActionCancel = 14,
    ApotrisActionPause = 15,
    ApotrisActionReset = 16,
} ApotrisAction;

typedef enum {
    ApotrisInputTypeKeyboard = 0,
    ApotrisInputTypeController = 1,
    ApotrisInputTypeTouch = 2,
} ApotrisInputType;

// What happens to Apotris's sound when another app (Music, a podcast, ...) is
// already playing. Persisted as the "audioMode" user default; see
// ApotrisAudio.mm.
typedef enum {
    ApotrisAudioStopOthers = 0, // non-mixable session: the other app is cut off
    ApotrisAudioPlayBoth = 1,   // both at full volume
    ApotrisAudioDuckOthers = 2, // the other app is lowered by iOS (default)
    ApotrisAudioDuckGame = 3,   // WE lower ourselves while the other app plays
    ApotrisAudioMuteGame = 4,   // WE go silent while the other app plays
    ApotrisAudioModeCount = 5,
} ApotrisAudioMode;

#ifdef __cplusplus
extern "C" {
#endif

// Lifecycle -----------------------------------------------------------------
// Spawns the game thread (runs upstream apotris_main). resourcePath becomes
// the working directory (bundle root containing assets/); documentsPath hosts
// Apotris.sav, replays, skins.
void apotris_start(const char* resourcePath, const char* documentsPath);
bool apotris_is_running(void);
void apotris_set_background(bool inBackground);
void apotris_request_save(void);

// Presentation --------------------------------------------------------------
// The Metal host view publishes its drawable size (pixels) and asks for the
// latest completed 512x512 RGBA frame each display tick. apotris_frame_tick
// also paces the game thread (call at ~60 Hz).
void apotris_set_drawable_size(int widthPixels, int heightPixels);
const uint8_t* apotris_latest_frame(void); // 512*512*4, RGBA, valid until next call
void apotris_frame_tick(void);

// Input ---------------------------------------------------------------------
// Raw halves, matching upstream's packed-key scheme: keyboard = SDL keycode,
// controller/touch = SDL_GameControllerButton value.
void apotris_key_event(int32_t rawKey, bool down, ApotrisInputType type);
// Gesture layer entry points: resolve the *current* in-game binding for an
// action, then inject its controller half as a virtual-gamepad touch press.
void apotris_action_event(ApotrisAction action, bool down); // held (soft drop)
void apotris_action_pulse(ApotrisAction action);            // 1-frame press
void apotris_analog_event(int axis, int value); // SDL axis id, [-32768, 32767]

// State ---------------------------------------------------------------------
bool apotris_in_gameplay(void); // GameScene active and not paused
uint32_t apotris_frame_counter(void);
const char* apotris_debug_state(void); // static buffer; DEBUG HUD only

// Native HUD (iOS portrait): the engine's side-info text is hidden and these
// values are shown in a native top bar instead. `valid` is 0 outside gameplay.
typedef struct {
    int valid;
    char mode[24];
    char time[16];
    int score;
    int level;
    int lines;
    int showScore;
    int showLevel;
    int showLines;
    int showTime;
} ApotrisHud;
void apotris_hud(ApotrisHud* out);
bool apotris_native_hud(void); // true when the native HUD layout is active

// Audio ---------------------------------------------------------------------
// Session category/options + a master mix gain on top of the engine's own
// volume settings. apotris_audio_boot() must run before the audio device is
// opened (the first setActive: is what interrupts other apps); the tick both
// polls "is another app playing" and re-asserts the gain, so call it every
// display tick.
void apotris_audio_boot(void);
void apotris_audio_set_mode(int mode); // ApotrisAudioMode
void apotris_audio_set_volume(float volume); // master gain, 0..1
void apotris_audio_reactivate(void);         // foregrounded: revive the session
void apotris_audio_tick(void);

// Haptics -------------------------------------------------------------------
// The engine's rumble path calls back into the shell (strength 0..8-ish, 0=stop).
typedef void (*ApotrisRumbleFn)(uint16_t strength);
void apotris_set_rumble_handler(ApotrisRumbleFn handler);

#ifdef __cplusplus
}
#endif

#pragma once
// iOS/visionOS platform backend for Apotris.
// Mirrors the liba_window/liba_android backend surface with zero SDL: SDL
// keycode / controller-button *values* come from sdl2_shim.h so the packed
// key encoding stays savefile-compatible across platforms. Implementation
// lives in the app shell (liba_ios.mm) so it can talk to Metal/UIKit.

#include <cinttypes>
#include <map>
#include <string>

#include "audio_files.h"
#include "liba_pc.h"
#include "sdl2_shim.h"

extern int KEY_A;
extern int KEY_B;
extern int KEY_L;
extern int KEY_R;
extern int KEY_UP;
extern int KEY_DOWN;
extern int KEY_LEFT;
extern int KEY_RIGHT;
extern int KEY_SELECT;
extern int KEY_START;

#define KEY_FULL 0xffffffff

extern void updateWindow(uint8_t*);
extern void refreshWindowSize();
extern bool closed();

extern void windowInit();

extern void key_poll();

extern void setFullscreen(bool);
extern void shaderInit(int);
extern void shaderDeinit();

extern uint32_t key_is_down(uint32_t);
extern uint32_t key_hit(uint32_t);
extern uint32_t key_released(uint32_t);
extern uint32_t key_first();
extern uint32_t keys_raw();

extern void setKey(int&, uint32_t);
extern void unbindDuplicateKey(int&, uint32_t);

extern int splitKey(uint32_t key);

extern float windowScale;
extern int rowStart;
extern int rowEnd;

extern std::map<int, std::string> keyToString;

std::string stringFromKey(uint32_t key);

enum class InputType { KEYBOARD, CONTROLLER, TOUCH };

extern InputType lastInputType;

// Input injection points for the shell's gesture/buttons/gamepad layers.
extern void pressKey(int key, InputType type);
extern void unpressKey(int key, InputType type);

INLINE u16 packKey(SDL_Keycode key) {
    return (key & 0xfff) | (((key & 0xf0000000) >> 16));
}

INLINE SDL_Keycode unpackKey(u16 key) {
    return (SDL_Keycode)(key & 0xfff) | (((key & 0xf000) << 16));
}

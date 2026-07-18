#pragma once
// SDL2 constants + minimal SDL_RWops for the iOS/visionOS backend (no SDL
// runtime). Values are copied verbatim from SDL 2.28.5 — they are baked into
// Apotris's packed key encoding and savefiles, so they must never drift.

#include <cstdint>
#include <cstdio>
#include <cstdlib>

typedef int32_t SDL_Keycode;
typedef int64_t Sint64;

#define SDLK_SCANCODE_MASK (1 << 30)
#define SDL_SCANCODE_TO_KEYCODE(X) ((X) | SDLK_SCANCODE_MASK)

// Printable keys are their ASCII values (SDL2 convention).
enum {
    SDLK_UNKNOWN = 0,
    SDLK_BACKSPACE = '\b',
    SDLK_TAB = '\t',
    SDLK_RETURN = '\r',
    SDLK_ESCAPE = '\x1B',
    SDLK_SPACE = ' ',
    SDLK_0 = '0', SDLK_1 = '1', SDLK_2 = '2', SDLK_3 = '3', SDLK_4 = '4',
    SDLK_5 = '5', SDLK_6 = '6', SDLK_7 = '7', SDLK_8 = '8', SDLK_9 = '9',
    SDLK_a = 'a', SDLK_b = 'b', SDLK_c = 'c', SDLK_d = 'd', SDLK_e = 'e',
    SDLK_f = 'f', SDLK_g = 'g', SDLK_h = 'h', SDLK_i = 'i', SDLK_j = 'j',
    SDLK_k = 'k', SDLK_l = 'l', SDLK_m = 'm', SDLK_n = 'n', SDLK_o = 'o',
    SDLK_p = 'p', SDLK_q = 'q', SDLK_r = 'r', SDLK_s = 's', SDLK_t = 't',
    SDLK_u = 'u', SDLK_v = 'v', SDLK_w = 'w', SDLK_x = 'x', SDLK_y = 'y',
    SDLK_z = 'z',
    SDLK_DELETE = '\x7F',
    // USB HID scancodes | mask (SDL2 SDL_SCANCODE_* values)
    SDLK_RIGHT = SDL_SCANCODE_TO_KEYCODE(79),
    SDLK_LEFT = SDL_SCANCODE_TO_KEYCODE(80),
    SDLK_DOWN = SDL_SCANCODE_TO_KEYCODE(81),
    SDLK_UP = SDL_SCANCODE_TO_KEYCODE(82),
    SDLK_LCTRL = SDL_SCANCODE_TO_KEYCODE(224),
    SDLK_LSHIFT = SDL_SCANCODE_TO_KEYCODE(225),
    SDLK_RSHIFT = SDL_SCANCODE_TO_KEYCODE(229),
};

typedef enum {
    SDL_CONTROLLER_BUTTON_INVALID = -1,
    SDL_CONTROLLER_BUTTON_A = 0,
    SDL_CONTROLLER_BUTTON_B = 1,
    SDL_CONTROLLER_BUTTON_X = 2,
    SDL_CONTROLLER_BUTTON_Y = 3,
    SDL_CONTROLLER_BUTTON_BACK = 4,
    SDL_CONTROLLER_BUTTON_GUIDE = 5,
    SDL_CONTROLLER_BUTTON_START = 6,
    SDL_CONTROLLER_BUTTON_LEFTSTICK = 7,
    SDL_CONTROLLER_BUTTON_RIGHTSTICK = 8,
    SDL_CONTROLLER_BUTTON_LEFTSHOULDER = 9,
    SDL_CONTROLLER_BUTTON_RIGHTSHOULDER = 10,
    SDL_CONTROLLER_BUTTON_DPAD_UP = 11,
    SDL_CONTROLLER_BUTTON_DPAD_DOWN = 12,
    SDL_CONTROLLER_BUTTON_DPAD_LEFT = 13,
    SDL_CONTROLLER_BUTTON_DPAD_RIGHT = 14,
    SDL_CONTROLLER_BUTTON_MISC1 = 15,
    SDL_CONTROLLER_BUTTON_PADDLE1 = 16,
    SDL_CONTROLLER_BUTTON_PADDLE2 = 17,
    SDL_CONTROLLER_BUTTON_PADDLE3 = 18,
    SDL_CONTROLLER_BUTTON_PADDLE4 = 19,
    SDL_CONTROLLER_BUTTON_TOUCHPAD = 20,
    SDL_CONTROLLER_BUTTON_MAX = 21,
} SDL_GameControllerButton;

typedef enum {
    SDL_CONTROLLER_AXIS_INVALID = -1,
    SDL_CONTROLLER_AXIS_LEFTX = 0,
    SDL_CONTROLLER_AXIS_LEFTY = 1,
    SDL_CONTROLLER_AXIS_RIGHTX = 2,
    SDL_CONTROLLER_AXIS_RIGHTY = 3,
    SDL_CONTROLLER_AXIS_TRIGGERLEFT = 4,
    SDL_CONTROLLER_AXIS_TRIGGERRIGHT = 5,
    SDL_CONTROLLER_AXIS_MAX = 6,
} SDL_GameControllerAxis;

// --- stdio-backed SDL_RWops subset (exactly what liba_sdl_audio.cpp uses) ---

typedef struct SDL_RWops {
    FILE* f;
} SDL_RWops;

static inline SDL_RWops* SDL_RWFromFile(const char* path, const char* mode) {
    FILE* f = fopen(path, mode);
    if (!f)
        return nullptr;
    SDL_RWops* rw = (SDL_RWops*)malloc(sizeof(SDL_RWops));
    rw->f = f;
    return rw;
}

static inline Sint64 SDL_RWsize(SDL_RWops* rw) {
    long pos = ftell(rw->f);
    fseek(rw->f, 0, SEEK_END);
    long size = ftell(rw->f);
    fseek(rw->f, pos, SEEK_SET);
    return (Sint64)size;
}

static inline size_t SDL_RWread(SDL_RWops* rw, void* ptr, size_t size,
                                size_t maxnum) {
    return fread(ptr, size, maxnum, rw->f);
}

static inline int SDL_RWclose(SDL_RWops* rw) {
    int r = fclose(rw->f);
    free(rw);
    return r;
}

static inline void* SDL_LoadFile(const char* path, size_t* datasize) {
    if (datasize)
        *datasize = 0;
    FILE* f = fopen(path, "rb");
    if (!f)
        return nullptr;
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (size < 0) {
        fclose(f);
        return nullptr;
    }
    char* buf = (char*)malloc((size_t)size + 1);
    size_t got = fread(buf, 1, (size_t)size, f);
    fclose(f);
    buf[got] = '\0';
    if (datasize)
        *datasize = got;
    return buf;
}

#define SDL_free free

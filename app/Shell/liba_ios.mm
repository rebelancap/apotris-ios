// liba_ios.mm — the iOS/visionOS platform backend for Apotris.
//
// Implements the backend surface declared in liba_ios.h (the same contract
// liba_window.cpp fulfills on desktop): framebuffer presentation handoff,
// key state, save paths, rumble, lifecycle. The game runs on a dedicated
// thread spawned by apotris_start(); UIKit/SwiftUI never blocks on it.
//
// Input model (matches upstream exactly — see docs/frame-map.md):
//   * key sets hold RAW halves: SDL keycodes (keyboard) or
//     SDL_GameControllerButton values (controller/touch).
//   * splitKey() picks which half of a packed binding to compare, based on
//     lastInputType. Touch injects controller halves — a virtual gamepad.
//   * All set mutation happens on the game thread by draining a locked op
//     queue inside handleInput(); the shell only enqueues.

#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#if !TARGET_OS_VISION
#import <UIKit/UIDevice.h>
#endif

#include <mach/mach_time.h>
#include <sys/stat.h>
#include <unistd.h>

#include <atomic>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_set>
#include <vector>

#include "platform.hpp"
#include "save.h"
#include "scene.hpp"

#include "AppBridge.h"

#include "soloud.h"

extern int apotris_main(int argc, char* argv[]);
extern void setGradient(u32 color);
extern void setScreenOffset(int x, int y);
extern void rumblePatternLoop();
extern int frameCounter;
extern bool paused;
extern bool demo;
extern BlockEngine::Game* game;
extern SoLoud::Soloud gSoloud;

extern int gameSeconds;
extern std::string timeToString(int frames, bool small);

void handleInput();
void updateBatteryInfo();

// iOS portrait hides the engine's side-info text (score/level/lines/timer) and
// shows it in a native top bar instead, freeing the sides so the board zooms
// bigger. visionOS keeps the engine's own layout (its 3:2 window fits it).
bool nativeHud = false;

// ---------------------------------------------------------------------------
// Backend globals (the liba_window-equivalent surface)
// ---------------------------------------------------------------------------

int KEY_A = (SDL_CONTROLLER_BUTTON_A << 16) | packKey(SDLK_RETURN);
int KEY_B = (SDL_CONTROLLER_BUTTON_B << 16) | packKey(SDLK_BACKSPACE);
int KEY_L = (SDL_CONTROLLER_BUTTON_LEFTSHOULDER << 16) | packKey(SDLK_1);
int KEY_R = (SDL_CONTROLLER_BUTTON_RIGHTSHOULDER << 16) | packKey(SDLK_2);
int KEY_UP = (SDL_CONTROLLER_BUTTON_DPAD_UP << 16) | packKey(SDLK_w);
int KEY_DOWN = (SDL_CONTROLLER_BUTTON_DPAD_DOWN << 16) | packKey(SDLK_s);
int KEY_LEFT = (SDL_CONTROLLER_BUTTON_DPAD_LEFT << 16) | packKey(SDLK_a);
int KEY_RIGHT = (SDL_CONTROLLER_BUTTON_DPAD_RIGHT << 16) | packKey(SDLK_d);
int KEY_SELECT = (SDL_CONTROLLER_BUTTON_BACK << 16) | packKey(SDLK_3);
int KEY_START = (SDL_CONTROLLER_BUTTON_START << 16) | packKey(SDLK_ESCAPE);

float windowScale = 2.0f;
int rowStart = 0;
int rowEnd = SCREEN_HEIGHT;
InputType lastInputType = InputType::TOUCH;
float fps = 60.0f;
int batteryPercentage = -1;
bool charging = false;

const char* homeDir = nullptr;

static int screenWidth = 1179;  // drawable pixels; updated by the shell
static int screenHeight = 2556;
static bool renderEnabled = true;

static std::unordered_set<uint32_t> currentlyPressed;
static std::unordered_set<uint32_t> currentKeys;
static std::unordered_set<uint32_t> previousKeys;

static std::string gDocumentsPath;
static std::string gResourcePath;

// ---------------------------------------------------------------------------
// Cross-thread plumbing
// ---------------------------------------------------------------------------

namespace {

enum class OpKind { Key, ActionHold, ActionPulse, Analog, Resize, Background, Save };

struct InputOp {
    OpKind kind;
    int a = 0; // key / action / axis / width / flag
    int b = 0; // down / value / height
    InputType type = InputType::TOUCH;
};

std::mutex qMutex;
std::vector<InputOp> pendingOps;

// 1-frame pulses: pressed at one drain, released at the next. A pulse of a
// key released this drain is deferred a frame so key_hit sees distinct edges.
struct Pulse {
    uint32_t rawKey;
    InputType type;
    bool applied = false;
};
std::vector<Pulse> pulses; // guarded by qMutex

std::mutex fbMutex;
uint8_t fbShared[512 * 512 * 4];
uint8_t fbOut[512 * 512 * 4];
std::atomic<uint32_t> fbSeq{0};

dispatch_semaphore_t frameSemaphore;
std::atomic<bool> gRunning{false};
std::atomic<bool> gInBackground{false};
std::atomic<bool> gQuit{false};

// visionOS can close the app's window (backgrounding it) and reopen it. That
// deactivates the AVAudioSession and stops SoLoud's AudioQueue, and nothing
// restarts them on reopen — music stays dead until a force-quit. Pause the
// backend on background and, on foreground, re-activate the session and restart
// the queue (SoLoud's coreaudio backend exposes AudioQueuePause/Start here).
static void suspendAppAudio() {
    if (gSoloud.mBackendPauseFunc)
        gSoloud.mBackendPauseFunc(&gSoloud);
}
static void resumeAppAudio() {
    [[AVAudioSession sharedInstance] setActive:YES error:nil];
    if (gSoloud.mBackendResumeFunc)
        gSoloud.mBackendResumeFunc(&gSoloud);
}

ApotrisRumbleFn gRumbleHandler = nullptr;

std::thread gGameThread;

uint64_t machNow() { return mach_absolute_time(); }
double machToMs(uint64_t t) {
    static mach_timebase_info_data_t tb = {0, 0};
    if (tb.denom == 0)
        mach_timebase_info(&tb);
    return (double)t * tb.numer / tb.denom / 1e6;
}

} // namespace

// ---------------------------------------------------------------------------
// Key state (bodies mirror liba_window.cpp so behavior is identical)
// ---------------------------------------------------------------------------

void pressKey(int key, InputType type) {
    lastInputType = type;
    currentlyPressed.insert(key);
}

void unpressKey(int key, InputType type) {
    lastInputType = type;
    currentlyPressed.erase(key);
}

void key_poll() {}

int splitKey(uint32_t key) {
    if (lastInputType == InputType::KEYBOARD) {
        return unpackKey(key & 0xffff);
    } else {
        return (key & 0xffff0000) >> 16;
    }
}

uint32_t key_is_down(uint32_t key) {
    if (key == KEY_FULL)
        return (!currentKeys.empty());
    key = splitKey(key);
    return currentKeys.count(key);
}

uint32_t key_hit(uint32_t key) {
    if (key == KEY_FULL)
        return (previousKeys.empty() && !currentKeys.empty());
    key = splitKey(key);
    bool prev = previousKeys.count(key);
    bool curr = currentKeys.count(key);
    return (!prev && curr);
}

uint32_t key_released(uint32_t key) {
    if (key == KEY_FULL)
        return (!previousKeys.empty() && currentKeys.empty());
    key = splitKey(key);
    bool prev = previousKeys.count(key);
    bool curr = currentKeys.count(key);
    return (prev && !curr);
}

uint32_t key_first() {
    if (currentKeys.empty())
        return KEY_FULL - 1;
    for (auto key : currentKeys) {
        if (!previousKeys.count(key))
            return key;
    }
    return KEY_FULL - 1;
}

uint32_t keys_raw() {
    if (currentKeys.empty())
        return KEY_FULL - 1;
    u32 allKeys = KEY_FULL;
    for (auto key : currentKeys)
        allKeys ^= key;
    return allKeys;
}

std::map<int, std::string> keyToString = {
    {SDL_CONTROLLER_BUTTON_A, "A"},
    {SDL_CONTROLLER_BUTTON_B, "B"},
    {SDL_CONTROLLER_BUTTON_X, "X"},
    {SDL_CONTROLLER_BUTTON_Y, "Y"},
    {SDL_CONTROLLER_BUTTON_BACK, "Select"},
    {SDL_CONTROLLER_BUTTON_START, "Start"},
    {SDL_CONTROLLER_BUTTON_DPAD_LEFT, "Left"},
    {SDL_CONTROLLER_BUTTON_DPAD_UP, "Up"},
    {SDL_CONTROLLER_BUTTON_DPAD_RIGHT, "Right"},
    {SDL_CONTROLLER_BUTTON_DPAD_DOWN, "Down"},
    {SDL_CONTROLLER_BUTTON_LEFTSHOULDER, "LB"},
    {SDL_CONTROLLER_BUTTON_RIGHTSHOULDER, "RB"},
    {SDL_CONTROLLER_BUTTON_LEFTSTICK, "LS"},
    {SDL_CONTROLLER_BUTTON_RIGHTSTICK, "RS"},
    {(1 << 14) | (0 << 5) | (0), "Left +X"},
    {(1 << 14) | (1 << 5) | (0), "Left -X"},
    {(1 << 14) | (0 << 5) | (1), "Left +Y"},
    {(1 << 14) | (1 << 5) | (1), "Left -Y"},
    {(1 << 14) | (0 << 5) | (2), "Right +X"},
    {(1 << 14) | (1 << 5) | (2), "Right -X"},
    {(1 << 14) | (0 << 5) | (3), "Right +Y"},
    {(1 << 14) | (1 << 5) | (3), "Right -Y"},
    {(1 << 14) | (0 << 5) | (4), "LT"},
    {(1 << 14) | (0 << 5) | (5), "RT"},
    {0xffff, ""},
};

static std::string keyboardKeyName(SDL_Keycode key) {
    if (key >= 'a' && key <= 'z')
        return std::string(1, (char)(key - 'a' + 'A'));
    if (key >= '0' && key <= '9')
        return std::string(1, (char)key);
    switch (key) {
    case SDLK_RETURN: return "Return";
    case SDLK_ESCAPE: return "Esc";
    case SDLK_BACKSPACE: return "Backspace";
    case SDLK_SPACE: return "Space";
    case SDLK_TAB: return "Tab";
    case SDLK_UP: return "Up";
    case SDLK_DOWN: return "Down";
    case SDLK_LEFT: return "Left";
    case SDLK_RIGHT: return "Right";
    case SDLK_LSHIFT: return "LShift";
    case SDLK_RSHIFT: return "RShift";
    case SDLK_LCTRL: return "LCtrl";
    default: {
        char buf[16];
        snprintf(buf, sizeof(buf), "Key %d", (int)key);
        return buf;
    }
    }
}

std::string stringFromKey(uint32_t key) {
    if (lastInputType == InputType::KEYBOARD) {
        key = unpackKey(key & 0xffff);
        if (key == 0xffff)
            return "";
        return keyboardKeyName((SDL_Keycode)key);
    } else {
        return keyToString[key >> 16];
    }
}

void setKey(int& dest, uint32_t key) {
    if (lastInputType == InputType::KEYBOARD) {
        dest = (dest & 0xffff0000) | packKey(key);
    } else {
        dest = (dest & 0xffff) | (key << 16);
    }
}

void unbindDuplicateKey(int& dest, uint32_t key) {
    if (lastInputType == InputType::KEYBOARD) {
        if ((dest & 0xffff) == (key & 0xffff))
            dest = (dest & 0xffff0000) | 0xfffe;
    } else {
        if (((uint32_t)dest >> 16) == key)
            dest = (dest & 0xffff) | (0xfffe << 16);
    }
}

#define ANALOG_DEADZONE 8000

static void handleAnalogInputRaw(int axis, int value) {
    lastInputType = InputType::CONTROLLER;
    int key = (axis & 0xf) | (1 << 14);
    if (value > ANALOG_DEADZONE) {
        pressKey(key, InputType::CONTROLLER);
        unpressKey(key | (1 << 5), InputType::CONTROLLER);
    } else if (value < -ANALOG_DEADZONE) {
        pressKey(key | (1 << 5), InputType::CONTROLLER);
        unpressKey(key, InputType::CONTROLLER);
    } else {
        unpressKey(key, InputType::CONTROLLER);
        unpressKey(key | (1 << 5), InputType::CONTROLLER);
    }
}

// ---------------------------------------------------------------------------
// Action resolution (gestures → the game's own live bindings)
// ---------------------------------------------------------------------------

static int packedKeyForAction(int action) {
    if (savefile == nullptr)
        return 0;
    const GameKeys& k = savefile->settings.keys;
    const MenuKeys& m = savefile->settings.menuKeys;
    switch ((ApotrisAction)action) {
    case ApotrisActionMoveLeft: return k.moveLeft;
    case ApotrisActionMoveRight: return k.moveRight;
    case ApotrisActionRotateCW: return k.rotateCW;
    case ApotrisActionRotateCCW: return k.rotateCCW;
    case ApotrisActionRotate180: return k.rotate180;
    case ApotrisActionSoftDrop: return k.softDrop;
    case ApotrisActionHardDrop: return k.hardDrop;
    case ApotrisActionHold: return k.hold;
    case ApotrisActionZone: return k.zone;
    case ApotrisActionMenuUp: return m.up;
    case ApotrisActionMenuDown: return m.down;
    case ApotrisActionMenuLeft: return m.left;
    case ApotrisActionMenuRight: return m.right;
    case ApotrisActionConfirm: return m.confirm;
    case ApotrisActionCancel: return m.cancel;
    case ApotrisActionPause: return m.pause;
    case ApotrisActionReset: return m.reset;
    }
    return 0;
}

static int controllerHalf(int packed) { return ((uint32_t)packed >> 16) & 0xffff; }

// ---------------------------------------------------------------------------
// Per-frame input pump (game thread, called from updateWindow)
// ---------------------------------------------------------------------------

void handleInput() {
    {
        std::lock_guard<std::mutex> lock(qMutex);

        // Release pulses applied last frame; defer same-key re-presses one
        // frame so key_hit sees distinct edges at a steady 30 Hz cadence.
        std::unordered_set<uint32_t> releasedNow;
        for (auto it = pulses.begin(); it != pulses.end();) {
            if (it->applied) {
                unpressKey(it->rawKey, it->type);
                releasedNow.insert(it->rawKey);
                it = pulses.erase(it);
            } else {
                ++it;
            }
        }

        std::vector<InputOp> requeued;
        std::unordered_set<uint32_t> downedThisDrain;
        for (const auto& op : pendingOps) {
            switch (op.kind) {
            case OpKind::Key:
                if (op.b) {
                    pressKey(op.a, op.type);
                    downedThisDrain.insert((uint32_t)op.a);
                } else if (downedThisDrain.count((uint32_t)op.a)) {
                    // Press and release landed inside one frame (a fast GB
                    // button tap): hold the release until the next drain so
                    // key_hit sees the press.
                    requeued.push_back(op);
                } else {
                    unpressKey(op.a, op.type);
                }
                break;
            case OpKind::ActionHold: {
                int key = controllerHalf(packedKeyForAction(op.a));
                if (op.b)
                    pressKey(key, InputType::TOUCH);
                else
                    unpressKey(key, InputType::TOUCH);
                break;
            }
            case OpKind::ActionPulse: {
                int key = controllerHalf(packedKeyForAction(op.a));
                pulses.push_back({(uint32_t)key, InputType::TOUCH, false});
                break;
            }
            case OpKind::Analog:
                handleAnalogInputRaw(op.a, op.b);
                break;
            case OpKind::Resize:
                screenWidth = op.a;
                screenHeight = op.b;
                refreshWindowSize();
                break;
            case OpKind::Background:
                gInBackground = op.a != 0;
                if (gInBackground) {
                    // Mirror liba_android: pause gameplay, unstick keys.
                    if (savefile != nullptr)
                        paused = true;
                    currentlyPressed.clear();
                    suspendAppAudio();
                } else {
                    resumeAppAudio();
                }
                break;
            case OpKind::Save:
                if (savefile != nullptr)
                    saveSavefile();
                break;
            }
        }
        pendingOps = std::move(requeued);

        for (auto& p : pulses) {
            if (!p.applied && !releasedNow.count(p.rawKey)) {
                pressKey(p.rawKey, p.type);
                p.applied = true;
            }
        }
    }

    previousKeys = currentKeys;
    currentKeys.clear();
    currentKeys = currentlyPressed;
}

// ---------------------------------------------------------------------------
// Present + pacing (game thread)
// ---------------------------------------------------------------------------

static uint64_t lastFrameMach = 0;

void updateWindow(uint8_t* framebuffer) {
    // Re-fit when entering/leaving gameplay so the board zooms in for play but
    // menus keep the full-width layout (native HUD only).
    if (nativeHud) {
        static bool lastInGameplay = false;
        bool ig = (scene != nullptr &&
                   dynamic_cast<GameScene*>(scene) != nullptr && !demo);
        if (ig != lastInGameplay) {
            lastInGameplay = ig;
            refreshWindowSize();
        }
    }

    if (renderEnabled) {
        std::lock_guard<std::mutex> lock(fbMutex);
        memcpy(fbShared, framebuffer, sizeof(fbShared));
        fbSeq++;
    }

    handleInput();

    // Pace: one game frame per display tick (the shell signals at ~60 Hz).
    // While backgrounded, park here — draining ops each wakeup so the
    // foreground signal (an op) can resume us. Timeout keeps quit checkable.
    long waited = dispatch_semaphore_wait(
        frameSemaphore, dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC));
    while (gInBackground && !gQuit) {
        dispatch_semaphore_wait(frameSemaphore,
                                dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC));
        std::lock_guard<std::mutex> lock(qMutex);
        for (const auto& op : pendingOps) {
            if (op.kind == OpKind::Background) {
                gInBackground = op.a != 0;
                if (!gInBackground)
                    resumeAppAudio(); // foregrounded: revive session + queue
            } else if (op.kind == OpKind::Save && savefile != nullptr)
                saveSavefile();
        }
        pendingOps.clear();
    }
    (void)waited;

    uint64_t now = machNow();
    if (lastFrameMach != 0) {
        double ms = machToMs(now - lastFrameMach);
        if (ms > 0.1)
            fps = (float)(1000.0 / ms);
    }
    lastFrameMach = now;

    updateBatteryInfo();
}

// The 240x160 game content sits centered in the 512x512 canvas (which the
// gradient fills entirely). We scale so the content fills the screen with a
// small margin, and *always* enough that the square canvas covers the whole
// screen — so the gradient reaches every edge (no black bars on iOS, no
// window letterbox on visionOS). Desktop's zoom/integerScale settings don't
// apply to a fixed device screen, so they're ignored here.
static const double kContentW = 240.0, kContentH = 160.0;
// Hold (left edge ~x40) · board (x80-160) · next (right edge ~x205), as a
// width centered on the canvas — what to fit when the side-info columns are
// hidden by the native HUD. Snug so the board zooms as large as possible
// while keeping hold + next on screen.
static const double kGameRowW = 172.0;

void refreshWindowSize() {
    if (screenWidth <= 0 || screenHeight <= 0)
        return;

    // iOS portrait uses the native HUD, so the engine's side-info columns are
    // hidden — fit to the narrower game row (hold · board · next) instead of
    // the full 240 strip, which zooms the board substantially bigger.
    bool portrait = screenWidth < screenHeight;
#if TARGET_OS_VISION
    nativeHud = false;
#else
    nativeHud = portrait;
#endif
    // Only zoom into the narrow game row during actual gameplay; menus use
    // the full 240-wide layout and would otherwise be cropped at the sides.
    bool inGameplay = (scene != nullptr &&
                       dynamic_cast<GameScene*>(scene) != nullptr && !demo);
    const double fitW = (nativeHud && inGameplay) ? kGameRowW : kContentW;

    // Fit the content to whichever screen dimension is the tighter fit.
    // Width-limited (portrait): fill nearly to the edges so the board is as
    // big as possible. Height-limited (visionOS 3:2): leave a small even
    // gradient border.
    bool widthLimited = (screenWidth * kContentH <= screenHeight * fitW);
    double wsFit = widthLimited ? 0.98 * screenWidth / fitW
                                : 0.90 * screenHeight / kContentH;
    // Guarantee the 512 canvas covers the screen (small overscan to kill any
    // seam from rounding) without cropping the menu width more than necessary.
    double wsCover = std::max(screenWidth, screenHeight) / (double)SCREEN_WIDTH * 1.005;
    windowScale = (float)std::max(wsFit, wsCover);

    rowStart = (SCREEN_HEIGHT - (screenHeight / windowScale)) / 2;
    rowEnd = (SCREEN_HEIGHT + (screenHeight / windowScale)) / 2;
    if (rowStart < 0)
        rowStart = 0;
    if (rowEnd > SCREEN_HEIGHT)
        rowEnd = SCREEN_HEIGHT;

    if (savefile != nullptr)
        setGradient(savefile->settings.backgroundGradient);

    // Center the content in the canvas (and thus on screen).
    setScreenOffset((SCREEN_WIDTH - 240) / 2, (SCREEN_HEIGHT - 160) / 2);
}

bool closed() {
    songEndHandler();
    rumblePatternLoop();
    return !gQuit;
}

void toggleRendering(bool r) { renderEnabled = r; }

// ---------------------------------------------------------------------------
// Rumble → shell haptics
// ---------------------------------------------------------------------------

void initRumble() {}

void rumbleOutput(uint16_t strength) {
    if (gRumbleHandler)
        gRumbleHandler(strength);
}

void rumbleStop() {
    if (gRumbleHandler)
        gRumbleHandler(0);
}

// ---------------------------------------------------------------------------
// Stubs (desktop-only surface the engine links against)
// ---------------------------------------------------------------------------

void setFullscreen(bool) {}
void shaderInit(int) {}
void shaderDeinit() {}

void quit() {
    // iOS apps don't self-terminate; save and stop the loop if ever reached.
    if (savefile != nullptr)
        saveSavefile();
    gQuit = true;
}

// ---------------------------------------------------------------------------
// Saves (Documents/Apotris/Apotris.sav — same 32K format as desktop)
// ---------------------------------------------------------------------------

std::string savefileDir() { return gDocumentsPath + "/Apotris"; }

std::string getSavefilePath() {
    mkdir(savefileDir().c_str(), 0755);
    return savefileDir() + "/Apotris.sav";
}

void loadSavefile() {
    std::string filePath = getSavefilePath();
    FILE* f = fopen(filePath.c_str(), "rb");
    if (!f)
        return;
    if (savefile == nullptr)
        savefile = new Save();
    size_t got = fread((char*)savefile, 1, sizeof(Save), f);
    fclose(f);
    if (got != sizeof(Save))
        log("Error when trying to load save.");
}

void saveSavefile() {
    std::string filePath = getSavefilePath();
    const int saveSize = 1 << 15;
    static char temp[saveSize];
    memset(temp, 0, saveSize);
    memcpy(temp, (char*)savefile, sizeof(Save));
    FILE* f = fopen(filePath.c_str(), "wb");
    if (!f) {
        log("Error when trying to write save.");
        return;
    }
    size_t wrote = fwrite(temp, 1, saveSize, f);
    fclose(f);
    if (wrote != saveSize)
        log("Error when trying to write save.");
}

void updateBatteryInfo() {
#if !TARGET_OS_VISION
    // UIDevice monitoring is enabled at startup on the main thread; reads
    // here are cheap value fetches.
    static int counter = 0;
    if (counter++ % 300 != 0)
        return;
    float level = [UIDevice currentDevice].batteryLevel;
    UIDeviceBatteryState state = [UIDevice currentDevice].batteryState;
    batteryPercentage = level < 0 ? -1 : (int)(level * 100);
    charging = state == UIDeviceBatteryStateCharging ||
               state == UIDeviceBatteryStateFull;
#else
    batteryPercentage = -1;
    charging = false;
#endif
}

// ---------------------------------------------------------------------------
// windowInit (called by platformInit on the game thread)
// ---------------------------------------------------------------------------

void windowInit() {
    refreshWindowSize();
    loadAudio("");
}

// ---------------------------------------------------------------------------
// C bridge for the Swift shell
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Autoplay driver (verification): APOTRIS_AUTOPLAY env var holds a script of
// semicolon-separated ops — w<ms> wait, p<ACT> pulse, h<ACT> hold, r<ACT>
// release. Actions: L R CW CCW 180 SD HD HOLD ZONE MU MD ML MR OK BK PS RST.
// Drives the exact same bridge path as real input. Harmless in release: only
// runs when the env var is present.
// ---------------------------------------------------------------------------

static int actionFromToken(const std::string& t) {
    static const std::pair<const char*, int> table[] = {
        {"L", ApotrisActionMoveLeft},   {"R", ApotrisActionMoveRight},
        {"CW", ApotrisActionRotateCW},  {"CCW", ApotrisActionRotateCCW},
        {"180", ApotrisActionRotate180},{"SD", ApotrisActionSoftDrop},
        {"HD", ApotrisActionHardDrop},  {"HOLD", ApotrisActionHold},
        {"ZONE", ApotrisActionZone},    {"MU", ApotrisActionMenuUp},
        {"MD", ApotrisActionMenuDown},  {"ML", ApotrisActionMenuLeft},
        {"MR", ApotrisActionMenuRight}, {"OK", ApotrisActionConfirm},
        {"BK", ApotrisActionCancel},    {"PS", ApotrisActionPause},
        {"RST", ApotrisActionReset},
    };
    for (auto& e : table)
        if (t == e.first)
            return e.second;
    return -1;
}

static void runAutoplay(std::string script) {
    std::thread([script] {
        pthread_setname_np("apotris-autoplay");
        size_t pos = 0;
        while (pos < script.size()) {
            size_t end = script.find(';', pos);
            if (end == std::string::npos)
                end = script.size();
            std::string tok = script.substr(pos, end - pos);
            pos = end + 1;
            if (tok.empty())
                continue;
            char op = tok[0];
            std::string arg = tok.substr(1);
            if (op == 'w') {
                usleep((useconds_t)(atoi(arg.c_str()) * 1000));
            } else if (op == 'p' || op == 'h' || op == 'r') {
                int action = actionFromToken(arg);
                if (action < 0) {
                    fprintf(stderr, "autoplay: bad action '%s'\n", arg.c_str());
                    continue;
                }
                fprintf(stdout, "autoplay: %c %s\n", op, arg.c_str());
                if (op == 'p')
                    apotris_action_pulse((ApotrisAction)action);
                else
                    apotris_action_event((ApotrisAction)action, op == 'h');
            }
        }
        fprintf(stdout, "autoplay: done\n");
    }).detach();
}

extern "C" {

void apotris_start(const char* resourcePath, const char* documentsPath) {
    if (gRunning.exchange(true))
        return;

#ifdef APOTRIS_LOG_TO_DOCS
    // Deterministic log capture for the simulator loop: everything the
    // engine prints lands in Documents/apotris.log.
    std::string logPath = std::string(documentsPath) + "/apotris.log";
    freopen(logPath.c_str(), "w", stdout);
    freopen(logPath.c_str(), "a", stderr);
#endif
    setvbuf(stdout, nullptr, _IOLBF, 0);
    setvbuf(stderr, nullptr, _IONBF, 0);

    gResourcePath = resourcePath;
    gDocumentsPath = documentsPath;
    homeDir = strdup(documentsPath);

    frameSemaphore = dispatch_semaphore_create(0);

    NSError* err = nil;
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryAmbient
                                           error:&err];
    [[AVAudioSession sharedInstance] setActive:YES error:nil];
#if !TARGET_OS_VISION
    [UIDevice currentDevice].batteryMonitoringEnabled = YES;
#endif

    chdir(gResourcePath.c_str());

    gGameThread = std::thread([] {
        pthread_setname_np("apotris-game");
        apotris_main(0, nullptr);
    });
    gGameThread.detach();

    if (const char* script = getenv("APOTRIS_AUTOPLAY"))
        runAutoplay(script);
}

bool apotris_is_running(void) { return gRunning; }

void apotris_set_drawable_size(int widthPixels, int heightPixels) {
    std::lock_guard<std::mutex> lock(qMutex);
    pendingOps.push_back({OpKind::Resize, widthPixels, heightPixels});
}

const uint8_t* apotris_latest_frame(void) {
    std::lock_guard<std::mutex> lock(fbMutex);
    memcpy(fbOut, fbShared, sizeof(fbOut));
    return fbOut;
}

void apotris_frame_tick(void) {
    if (frameSemaphore)
        dispatch_semaphore_signal(frameSemaphore);
}

void apotris_key_event(int32_t rawKey, bool down, ApotrisInputType type) {
    std::lock_guard<std::mutex> lock(qMutex);
    pendingOps.push_back(
        {OpKind::Key, rawKey, down ? 1 : 0, (InputType)type});
}

void apotris_action_event(ApotrisAction action, bool down) {
    std::lock_guard<std::mutex> lock(qMutex);
    pendingOps.push_back({OpKind::ActionHold, (int)action, down ? 1 : 0});
}

void apotris_action_pulse(ApotrisAction action) {
    std::lock_guard<std::mutex> lock(qMutex);
    pendingOps.push_back({OpKind::ActionPulse, (int)action, 0});
}

void apotris_analog_event(int axis, int value) {
    std::lock_guard<std::mutex> lock(qMutex);
    pendingOps.push_back({OpKind::Analog, axis, value});
}

bool apotris_in_gameplay(void) {
    // The title attract demo is a GameScene too (with `demo` set) — it must
    // read as menu context so gestures dismiss it instead of playing it.
    return scene != nullptr && dynamic_cast<GameScene*>(scene) != nullptr &&
           !paused && !demo;
}

uint32_t apotris_frame_counter(void) { return (uint32_t)frameCounter; }

const char* apotris_debug_state(void) {
    static char buf[200];
    int px = -1, py = -1, rot = -1, pieces = -1;
    if (game != nullptr) {
        px = game->pawn.x;
        py = game->pawn.y;
        rot = game->pawn.rotation;
        pieces = game->pieceCounter;
    }
    snprintf(buf, sizeof(buf),
             "g=%d p=%d pc=%d fps=%.0f | scr=%dx%d ws=%.2f rows=%d-%d",
             apotris_in_gameplay() ? 1 : 0, paused ? 1 : 0, pieces, fps,
             screenWidth, screenHeight, windowScale, rowStart, rowEnd);
    return buf;
}

bool apotris_native_hud(void) { return nativeHud; }

// Modes enum (blockEngine.hpp): MARATHON=1 SPRINT=2 DIG=3 BATTLE=4 ULTRA=5
// BLITZ=6 COMBO=7 SURVIVAL=8 CLASSIC=9 MASTER=10 TRAINING=11 ZEN=12 DEATH=13
static const char* kModeNames[] = {"",         "Marathon", "Sprint",
                                   "Dig",      "Battle",   "Ultra",
                                   "Blitz",    "Combo",    "Survival",
                                   "Classic",  "Master",   "Training",
                                   "Zen",      "Death"};

void apotris_hud(ApotrisHud* out) {
    memset(out, 0, sizeof(*out));
    // Frozen stats are fine during pause, but not menus or the attract demo.
    if (game == nullptr || scene == nullptr ||
        dynamic_cast<GameScene*>(scene) == nullptr || demo)
        return;
    out->valid = 1;
    int gm = game->gameMode;
    snprintf(out->mode, sizeof(out->mode), "%s",
             (gm >= 0 && gm < (int)(sizeof(kModeNames) / sizeof(*kModeNames)))
                 ? kModeNames[gm]
                 : "");
    snprintf(out->time, sizeof(out->time), "%s",
             timeToString(gameSeconds, false).c_str());
    out->score = game->score;
    out->level = game->level;
    out->lines = game->linesCleared;
    out->showTime = (gm != 11 && gm != 12);        // not Training/Zen
    out->showScore = (gm == 1 || gm == 5 || gm == 6 || gm == 9); // Mar/Ultra/Blitz/Classic
    out->showLevel = (gm == 1 || gm == 9 || gm == 10 || gm == 13); // Mar/Classic/Master/Death
    out->showLines = (gm == 1 || gm == 2 || gm == 3 || gm == 9 || gm == 12);
    if (!out->showScore && !out->showLines)
        out->showLines = 1; // never show an empty bar
}

void apotris_set_background(bool inBackground) {
    {
        std::lock_guard<std::mutex> lock(qMutex);
        pendingOps.push_back({OpKind::Background, inBackground ? 1 : 0, 0});
    }
    // Wake the parked loop so the flag flip is seen promptly.
    if (frameSemaphore)
        dispatch_semaphore_signal(frameSemaphore);
}

void apotris_request_save(void) {
    std::lock_guard<std::mutex> lock(qMutex);
    pendingOps.push_back({OpKind::Save, 0, 0});
}

void apotris_set_rumble_handler(ApotrisRumbleFn handler) {
    gRumbleHandler = handler;
}

} // extern "C"

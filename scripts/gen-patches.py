#!/usr/bin/env python3
"""Regenerate overlay/patches/ from vendor/apotris + the edit rules below.

Every rule asserts its exact match count against the pristine vendor tree
(charter rule 3: a silent no-op edit is a shipped regression). Run after any
upstream pin bump; a count mismatch means the patch needs re-derivation.
"""
import difflib
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
VENDOR = ROOT / "vendor/apotris"
PATCHES = ROOT / "overlay/patches"


def gen(num: int, name: str, relpath: str, transforms):
    src = (VENDOR / relpath).read_text()
    out = src
    for old, new, count in transforms:
        found = out.count(old)
        assert found == count, (
            f"{name}: expected {count}x, found {found}x: {old[:70]!r}"
        )
        out = out.replace(old, new)
    diff = difflib.unified_diff(
        src.splitlines(keepends=True),
        out.splitlines(keepends=True),
        fromfile=f"a/{relpath}",
        tofile=f"b/{relpath}",
    )
    path = PATCHES / f"{num:04d}-{name}.patch"
    path.write_text("".join(diff))
    print(f"wrote {path.relative_to(ROOT)}")


APPLE_MOBILE = (
    "apple_mobile = host_machine.system() == 'darwin' and host_machine"
    ".subsystem() not in ['macos', 'darwin']"
)

gen(1, "meson-apple-mobile", "meson.build", [
    # macOS-only deployment flag must not leak into iOS/visionOS compiles
    (
        "elif host_machine.system() == 'darwin'\n"
        "    add_global_arguments('-mmacosx-version-min=10.15', language : ['cpp', 'c'])\n",
        "elif host_machine.system() == 'darwin'\n"
        "    if host_machine.subsystem() in ['macos', 'darwin']\n"
        "        add_global_arguments('-mmacosx-version-min=10.15', language : ['cpp', 'c'])\n"
        "    endif\n",
        1,
    ),
    # introduce the apple_mobile predicate at the top of the TE section
    (
        "    json = dependency('nlohmann_json', fallback: ['nlohmann_json', 'nlohmann_json_dep'])\n",
        f"    {APPLE_MOBILE}\n\n"
        "    json = dependency('nlohmann_json', fallback: ['nlohmann_json', 'nlohmann_json_dep'])\n",
        1,
    ),
    # no SDL2/SDL2_mixer at all on Apple mobile (the else branch would pull
    # the generic sdl2 wrap, so apple_mobile needs its own empty branch)
    (
        "        if host_machine.system() == 'darwin'\n"
        "            sdl2_dep = subproject(",
        "        if apple_mobile\n"
        "            message('Apple mobile: no SDL2/SDL2_mixer (D-005)')\n"
        "        elif host_machine.system() == 'darwin'\n"
        "            sdl2_dep = subproject(",
        1,
    ),
    # dependency set without SDL for Apple mobile
    (
        "    dependencies = [\n"
        "        dependency('threads'),\n"
        "        json,\n"
        "        ogg,\n"
        "        openmpt,\n"
        "        sdl_mixer,\n"
        "        opus,\n"
        "        tilengine,\n"
        "        sdl2_dep,\n"
        "        soloud,\n"
        "    ]\n",
        "    if apple_mobile\n"
        "        dependencies = [\n"
        "            dependency('threads'),\n"
        "            json,\n"
        "            ogg,\n"
        "            openmpt,\n"
        "            opus,\n"
        "            tilengine,\n"
        "            soloud,\n"
        "        ]\n"
        "    else\n"
        "        dependencies = [\n"
        "            dependency('threads'),\n"
        "            json,\n"
        "            ogg,\n"
        "            openmpt,\n"
        "            sdl_mixer,\n"
        "            opus,\n"
        "            tilengine,\n"
        "            sdl2_dep,\n"
        "            soloud,\n"
        "        ]\n"
        "    endif\n",
        1,
    ),
    # no cpr (HTTP update check) on Apple mobile
    (
        "    if host_machine.system() != 'horizon'\n"
        "        dependencies += dependency('cpr')\n"
        "    endif\n",
        "    if host_machine.system() != 'horizon' and not apple_mobile\n"
        "        dependencies += dependency('cpr')\n"
        "    endif\n",
        1,
    ),
    # Apple mobile keeps libdatachannel (online play, built with mbedTLS — see
    # patch 0010); the datachannel dependency line stays enabled. Only cpr
    # (desktop update-check) is excluded (handled in the cpr transform above).
    # platform defines: IOS instead of PC (online stays ON — no NO_ONLINE)
    (
        "    elif host_machine.system() != 'emscripten'\n"
        "        add_project_arguments('-DPC', language: ['cpp', 'c'])\n",
        "    elif apple_mobile\n"
        "        add_project_arguments('-DIOS', language: ['cpp', 'c'])\n"
        "    elif host_machine.system() != 'emscripten'\n"
        "        add_project_arguments('-DPC', language: ['cpp', 'c'])\n",
        1,
    ),
    (
        "    elif host_machine.system() == 'darwin'\n"
        "        link_args += '-mmacosx-version-min=10.15'\n",
        "    elif host_machine.system() == 'darwin'\n"
        "        if host_machine.subsystem() in ['macos', 'darwin']\n"
        "            link_args += '-mmacosx-version-min=10.15'\n"
        "        endif\n",
        1,
    ),
    # Apple mobile builds a static core library; the app shell links it
    (
        "        alias_target('apk', apk)\n"
        "    else\n"
        "        binary = executable(\n",
        "        alias_target('apk', apk)\n"
        "    elif apple_mobile\n"
        "        binary = static_library(\n"
        "            'apotris-core',\n"
        "            generated_files + sources,\n"
        "            include_directories: includes,\n"
        "            dependencies: dependencies,\n"
        "        )\n"
        "    else\n"
        "        binary = executable(\n",
        1,
    ),
])

gen(2, "platform-hpp-ios", "include/platform.hpp", [
    (
        "#ifdef ANDROID\n"
        "\n"
        "#include \"liba_android.h\"\n"
        "#include \"liba_pc.h\"\n"
        "#include \"liba_sdl_audio.hpp\"\n"
        "\n"
        "#define PLATFORM 1\n"
        "#endif\n",
        "#ifdef ANDROID\n"
        "\n"
        "#include \"liba_android.h\"\n"
        "#include \"liba_pc.h\"\n"
        "#include \"liba_sdl_audio.hpp\"\n"
        "\n"
        "#define PLATFORM 1\n"
        "#endif\n"
        "\n"
        "#ifdef IOS\n"
        "\n"
        "#include \"liba_ios.h\"\n"
        "#include \"liba_pc.h\"\n"
        "#include \"liba_sdl_audio.hpp\"\n"
        "\n"
        "#define PLATFORM 1\n"
        "#endif\n",
        1,
    ),
])

gen(3, "no-online-guards", "include/LinkWebRTC.hpp", [
    (
        "#ifndef SWITCH\n",
        "#if !defined(SWITCH) && !defined(NO_ONLINE)\n",
        3,
    ),
])

gen(4, "main-entry-ios", "source/main.cpp", [
    (
        "int main(int argc, char* argv[]) {\n"
        "    platformInit();\n",
        "#ifdef IOS\n"
        "// The app shell owns main() (SwiftUI); the game loop runs on its own thread.\n"
        "int apotris_main(int argc, char* argv[]) {\n"
        "#else\n"
        "int main(int argc, char* argv[]) {\n"
        "#endif\n"
        "    platformInit();\n",
        1,
    ),
    (
        "#include <string>\n",
        "#include <string>\n"
        "#include <cstdlib> // getenv/strtoul for the iOS dev test hook below\n",
        1,
    ),
    (
        "#ifndef MULTIBOOT\n"
        "    changeScene([]() { return new TitleScene(); });\n"
        "#else\n",
        "#ifndef MULTIBOOT\n"
        "#ifdef IOS\n"
        "    // Dev-only connection test hook (no effect unless the env var is set,\n"
        "    // which requires a debugging launch). APOTRIS_TEST_ROOM boots straight\n"
        "    // into a private Multi Battle room, bypassing menu nav so two simulators\n"
        "    // pair deterministically. APOTRIS_TEST_SEED gives each instance a\n"
        "    // distinct localId - randomId() draws from the game PRNG, so two fresh\n"
        "    // saves would otherwise collide and fail to pair.\n"
        "    if (const char* testRoom = getenv(\"APOTRIS_TEST_ROOM\");\n"
        "        testRoom && testRoom[0]) {\n"
        "        if (const char* s = getenv(\"APOTRIS_TEST_SEED\"))\n"
        "            randSetSeed((unsigned)strtoul(s, nullptr, 10));\n"
        "        std::string room(testRoom);\n"
        "        changeScene([room]() { return new MultBattleScene(room); });\n"
        "    } else\n"
        "#endif\n"
        "    changeScene([]() { return new TitleScene(); });\n"
        "#else\n",
        1,
    ),
    # Route multiplayer exceptions (e.g. a failed signaling connect) to the
    # MultiplayerExceptionScene on iOS too, not just PC. setUpPresentException
    # is defined in liba_pc.cpp, which the iOS core compiles. Without this the
    # main loop would clear exceptionReason and silently strand the player in a
    # dead MultBattleScene; with the LinkWebRTC catch (patch 12) it means a
    # dropped connection shows an error and returns to the menu instead of
    # aborting the app.
    (
        "#ifdef PC\n"
        "            setUpPresentException(localReason);\n",
        "#if defined(PC) || defined(IOS)\n"
        "            setUpPresentException(localReason);\n",
        1,
    ),
])

gen(5, "audio-io-ios", "source/liba_sdl_audio.cpp", [
    (
        "#if defined(PC) || defined(PORTMASTER) || defined(WEB) || defined(SWITCH) ||   \\\n"
        "    defined(ANDROID)\n",
        "#if defined(PC) || defined(PORTMASTER) || defined(WEB) || defined(SWITCH) ||   \\\n"
        "    defined(ANDROID) || defined(IOS)\n",
        1,
    ),
    (
        "#include <SDL.h>\n",
        "#ifdef IOS\n"
        "#include \"sdl2_shim.h\" // stdio-backed SDL_RWops + enum values, no SDL runtime\n"
        "#else\n"
        "#include <SDL.h>\n"
        "#endif\n",
        1,
    ),
])

gen(6, "soloud-coreaudio", "subprojects/SoLoud/meson.build", [
    (
        "if get_option('portmaster')\n"
        "    sources += files('src/backend/sdl/soloud_sdl2_dll.c')\n",
        "if host_machine.system() == 'darwin' and host_machine.subsystem() not in ['macos', 'darwin']\n"
        "    # Apple mobile (iOS/visionOS): AudioQueue backend, no SDL\n"
        "    sources += files('src/backend/coreaudio/soloud_coreaudio.cpp')\n"
        "    arg = '-DWITH_COREAUDIO=1'\n"
        "    deps += dependency('appleframeworks', modules : ['AudioToolbox', 'CoreFoundation'])\n"
        "elif get_option('portmaster')\n"
        "    sources += files('src/backend/sdl/soloud_sdl2_dll.c')\n",
        1,
    ),
])

gen(7, "tilengine-no-openssl", "subprojects/Tilengine/meson.build", [
    (
        "if host_machine.system() != 'horizon' and host_machine.system() != 'emscripten' and host_machine.system() != 'n3ds'\n"
        "  c_args += '-DHAVE_OPENSSL'\n",
        "if host_machine.system() != 'horizon' and host_machine.system() != 'emscripten' and host_machine.system() != 'n3ds' and (host_machine.system() != 'darwin' or host_machine.subsystem() in ['macos', 'darwin'])\n"
        "  c_args += '-DHAVE_OPENSSL'\n",
        1,
    ),
])


gen(8, "default-binds-ios", "source/saving.cpp", [
    # Controller-half defaults for game/menu bindings must apply on iOS too —
    # touch injection acts as a virtual gamepad, so without these halves every
    # binding is 0 and any press matches every action at once.
    (
        "#if defined(PC) || defined(WEB)\n",
        "#if defined(PC) || defined(WEB) || defined(IOS)\n",
        2,
    ),
])

gen(9, "native-hud-gate", "source/game.cpp", [
    # iOS portrait draws score/level/lines/timer in a native top bar instead,
    # so the engine's side-info columns are suppressed (freeing the sides for
    # a bigger board). Guarded by IOS so the macOS oracle is unaffected and
    # never references the backend-defined flag.
    (
        "void GameScene::showTimer() {\n",
        "#ifdef IOS\n"
        "extern bool nativeHud; // defined in the iOS backend (liba_ios.mm)\n"
        "#endif\n\n"
        "void GameScene::showTimer() {\n"
        "#ifdef IOS\n"
        "    if (nativeHud)\n"
        "        return;\n"
        "#endif\n",
        1,
    ),
    (
        "void GameScene::showText() {\n    int gm = game->gameMode;\n",
        "void GameScene::showText() {\n"
        "#ifdef IOS\n"
        "    if (nativeHud)\n"
        "        return;\n"
        "#endif\n"
        "    int gm = game->gameMode;\n",
        1,
    ),
])

gen(10, "libdatachannel-mbedtls-apple", "subprojects/libdatachannel/meson.build", [
    # Apple mobile builds libdatachannel's crypto with mbedTLS (via the CMake
    # subproject, like libjuice above) instead of OpenSSL, which doesn't
    # cross-compile cleanly for the iOS/visionOS SDKs.
    (
        "elif host_machine.system() == 'linux' or host_machine.system() == 'darwin' or host_machine.system() == 'android'\n"
        "    dependencies += dependency('openssl', fallback : ['openssl', 'openssl_dep'])\n",
        "elif host_machine.system() == 'darwin' and host_machine.subsystem() not in ['macos', 'darwin']\n"
        "    mbedtls_ucfg = meson.current_source_dir() / 'mbedtls_user_config.h'\n"
        "    mbedtls_opt = cmake.subproject_options()\n"
        "    mbedtls_opt.add_cmake_defines({'ENABLE_TESTING': false, 'ENABLE_PROGRAMS': false, 'BUILD_SHARED_LIBS': false, 'MBEDTLS_FATAL_WARNINGS': false, 'MBEDTLS_USER_CONFIG_FILE': mbedtls_ucfg})\n"
        "    mbedtls_sp = cmake.subproject('mbedtls', options : mbedtls_opt)\n"
        "    dependencies += mbedtls_sp.dependency('mbedtls')\n"
        "    dependencies += mbedtls_sp.dependency('mbedx509')\n"
        "    dependencies += mbedtls_sp.dependency('mbedcrypto')\n"
        "    add_project_arguments('-DUSE_MBEDTLS=1', language : ['c', 'cpp'])\n"
        "    add_project_arguments('-DMBEDTLS_USER_CONFIG_FILE=\"' + mbedtls_ucfg + '\"', language : ['c', 'cpp'])\n"
        "elif host_machine.system() == 'linux' or host_machine.system() == 'darwin' or host_machine.system() == 'android'\n"
        "    dependencies += dependency('openssl', fallback : ['openssl', 'openssl_dep'])\n",
        1,
    ),
])

gen(11, "ios-online-cacert", "include/LinkWebRTC.hpp", [
    # mbedTLS on iOS/visionOS has no access to the system trust store, so the
    # WebSocket must be pointed at the bundled CA cert to validate wss://
    # api.apotris.com. cwd is the app bundle root (set in apotris_start), so the
    # relative asset path resolves. Mirrors the Android/N3DS branches.
    (
        "#else\n"
        "        ws = std::make_shared<rtc::WebSocket>();\n"
        "#endif\n",
        "#elif defined(IOS)\n"
        "        ws = std::make_shared<rtc::WebSocket>(rtc::WebSocketConfiguration{\n"
        "            .caCertificatePemFile = \"assets/ssl/cacert.pem\",\n"
        "        });\n"
        "#else\n"
        "        ws = std::make_shared<rtc::WebSocket>();\n"
        "#endif\n",
        1,
    ),
])

gen(12, "ios-online-connect-failure", "include/LinkWebRTC.hpp", [
    # The desktop/iOS signaling path blocks on wsFuture until the WebSocket to
    # api.apotris.com opens or fails. activate() runs inside the game loop
    # (scene->update), so a failed connect must not abort or hang it:
    #   - an uncaught throw from get() aborts the whole app (real crash seen on
    #     a TCP timeout: onError -> set_exception -> get() rethrows);
    #   - a failure that only fires onClosed (e.g. a TLS/handshake error) never
    #     settled the promise at all, so get() blocked the game thread forever
    #     on "Waiting for connection...".
    # Fix: settle one shared, guarded promise from whichever callback fires
    # first, and wait with a timeout so get() can't block the game thread
    # forever. On timeout/failure just return, leaving the link "active but not
    # connected": the MultiplayerLink state machine then sits in
    # ConnectionInitializing showing "Waiting for connection..." -- responsive
    # (cancel returns to the menu, and a slow connect that completes after the
    # timeout is still picked up), instead of crashing, freezing, or (if we had
    # cleared `active`) spinning the Deactivated<->Activated reconnect loop every
    # frame and hammering the signaling server. shared_ptr capture keeps the
    # promise alive for a callback that fires after activate() returns (e.g. a
    # later session close).
    # (<atomic>/<chrono> come in transitively via rtc/rtc.hpp; <chrono> is also
    # already used in randomId(). Adding them here would collide with patch 3's
    # edit to the include guard, so we rely on the transitive include.)
    (
        "        std::promise<void> wsPromise;\n"
        "        auto wsFuture = wsPromise.get_future();\n"
        "\n"
        "        ws->onOpen([this, wws = make_weak_ptr(ws), &wsPromise]() {\n"
        "            std::cout << \"WebSocket connected, signaling ready\" << std::endl;\n"
        "            wsPromise.set_value();\n"
        "            if (auto shared_ws = wws.lock()) {\n"
        "                json playerInfo = {{ID, \"broadcast\"},\n"
        "                                   {TYPE, PLAYER_INFO},\n"
        "                                   {NAME, localPlayerName}};\n"
        "                shared_ws->send(playerInfo.dump());\n"
        "                std::cout << \"Sent player info to signaling server: \"\n"
        "                          << playerInfo.dump() << std::endl;\n"
        "            }\n"
        "        });\n"
        "\n"
        "        ws->onError([&wsPromise](const std::string& s) {\n"
        "            std::cout << \"WebSocket error\" << std::endl;\n"
        "            wsPromise.set_exception(\n"
        "                std::make_exception_ptr(std::runtime_error(s)));\n"
        "        });\n",
        "        auto wsPromise = std::make_shared<std::promise<void>>();\n"
        "        auto wsSettled = std::make_shared<std::atomic<bool>>(false);\n"
        "        auto wsFuture = wsPromise->get_future();\n"
        "        auto settle = [wsPromise, wsSettled](std::exception_ptr err) {\n"
        "            bool expected = false;\n"
        "            if (!wsSettled->compare_exchange_strong(expected, true))\n"
        "                return;\n"
        "            if (err)\n"
        "                wsPromise->set_exception(err);\n"
        "            else\n"
        "                wsPromise->set_value();\n"
        "        };\n"
        "\n"
        "        ws->onOpen([this, wws = make_weak_ptr(ws), settle]() {\n"
        "            std::cout << \"WebSocket connected, signaling ready\" << std::endl;\n"
        "            settle(nullptr);\n"
        "            if (auto shared_ws = wws.lock()) {\n"
        "                json playerInfo = {{ID, \"broadcast\"},\n"
        "                                   {TYPE, PLAYER_INFO},\n"
        "                                   {NAME, localPlayerName}};\n"
        "                shared_ws->send(playerInfo.dump());\n"
        "                std::cout << \"Sent player info to signaling server: \"\n"
        "                          << playerInfo.dump() << std::endl;\n"
        "            }\n"
        "        });\n"
        "\n"
        "        ws->onError([settle](const std::string& s) {\n"
        "            std::cout << \"WebSocket error: \" << s << std::endl;\n"
        "            settle(std::make_exception_ptr(std::runtime_error(s)));\n"
        "        });\n"
        "\n"
        "        ws->onClosed([settle]() {\n"
        "            std::cout << \"WebSocket closed\" << std::endl;\n"
        "            settle(std::make_exception_ptr(\n"
        "                std::runtime_error(\"closed before signaling ready\")));\n"
        "        });\n",
        1,
    ),
    (
        "#if !defined(WEB) && !defined(ANDROID)\n"
        "        std::cout << \"Waiting for signaling to be connected...\" << std::endl;\n"
        "        wsFuture.get();\n"
        "#endif\n",
        "#if !defined(WEB) && !defined(ANDROID)\n"
        "        std::cout << \"Waiting for signaling to be connected...\" << std::endl;\n"
        "        if (wsFuture.wait_for(std::chrono::seconds(15)) !=\n"
        "            std::future_status::ready) {\n"
        "            std::cout << \"Signaling connection timed out; still waiting\"\n"
        "                      << std::endl;\n"
        "            return;\n"
        "        }\n"
        "        try {\n"
        "            wsFuture.get();\n"
        "        } catch (const std::exception& e) {\n"
        "            std::cout << \"Signaling connection failed: \" << e.what()\n"
        "                      << std::endl;\n"
        "            return;\n"
        "        }\n"
        "#endif\n",
        1,
    ),
])

gen(13, "pause-menu-ios-confirm", "source/menus.cpp", [
    # Restart/Quit in the pause menu arm a 1-second hold-to-confirm that needs
    # key_is_down(confirm) held for 60 frames. Every iOS input is momentary -- a
    # gamepad tap, a touch tap, a visionOS gaze-pinch -- so the hold never
    # completes and the options are effectively dead (only Resume, an instant
    # press, works). Restructure so the completion is shared via a confirmDone
    # flag, and on iOS confirm on a second press / cancel on a cancel press,
    # showing the meter full as a "press to confirm" cue.
    (
        "            // Hold-to-confirm processing for Restart/Quit\n"
        "            if (confirmHoldAction >= 0) {\n"
        "                if (key_is_down(k.confirm)) {\n"
        "                    confirmHoldTimer++;\n"
        "\n"
        "                    // Play progress sfx every 1/8 second (~8 frames)\n"
        "                    if (confirmHoldTimer % 8 == 0) {\n"
        "                        sfx(SFX_SHIFT2);\n"
        "                    }\n"
        "\n"
        "                    // Show zone meter progress sprite\n"
        "                    int progress = confirmHoldTimer * 12 / 60;\n"
        "                    if (progress > 12)\n"
        "                        progress = 12;\n"
        "\n"
        "                    int meterX =\n"
        "                        (savefile->settings.aspectRatio != 0) ? 191 : 204;\n"
        "                    sprite_set_attr(confirmMeterSprite, ShapeSquare, 2, 256 + 3,\n"
        "                                    12, 0);\n"
        "                    sprite_enable_mosaic(confirmMeterSprite);\n"
        "                    sprite_set_pos(confirmMeterSprite, meterX, 124);\n"
        "                    sprite_unhide(confirmMeterSprite, 0);\n"
        "\n"
        "                    for (int i = 0; i < 12; i++) {\n"
        "                        if (i < progress)\n"
        "                            setPaletteColor(12 + 16, 4 + i, 0x7fff, 1);\n"
        "                        else\n"
        "                            setPaletteColor(12 + 16, 4 + i, 0x0c63, 1);\n"
        "                    }\n"
        "\n"
        "                    // Action completes after 1 second (60 frames)\n"
        "                    if (confirmHoldTimer >= 60) {\n"
        "                        sprite_hide(confirmMeterSprite);\n"
        "                        if (confirmHoldAction == 1) {\n"
        "                            addGameStats();\n"
        "                            startGame();\n"
        "                            changeScene([]() { return new GameScene(); });\n"
        "                            paused = false;\n"
        "                            count = false;\n"
        "                            sfx(SFX_MENUCONFIRM);\n"
        "                            return 0;\n"
        "                        } else if (confirmHoldAction == 3) {\n"
        "                            enableBlend(prevBld);\n"
        "                            sfx(SFX_MENUCANCEL);\n"
        "                            buildBG(3, 0, 27, 0, 1, true);\n"
        "                            addGameStats();\n"
        "                            playSongRandom(0);\n"
        "\n"
        "#ifdef MULTIBOOT\n"
        "                            changeScene([]() { return new MultBattleScene(); },\n"
        "                                        Transitions::FADE);\n"
        "#else\n"
        "                            changeScene([]() { return new MainMenuScene(); },\n"
        "                                        Transitions::FADE);\n"
        "#endif\n"
        "                            return 1;\n"
        "                        }\n"
        "                    }\n"
        "                } else {\n"
        "                    // Button released, cancel hold\n"
        "                    confirmHoldTimer = 0;\n"
        "                    confirmHoldAction = -1;\n"
        "                    sprite_hide(confirmMeterSprite);\n"
        "                }\n"
        "            } else if (key_hit(k.confirm)) {\n",
        "            // Hold-to-confirm processing for Restart/Quit\n"
        "            if (confirmHoldAction >= 0) {\n"
        "                bool confirmDone = false;\n"
        "#ifdef IOS\n"
        "                // A pause-menu option is only reached by a deliberate\n"
        "                // select, and visionOS pad confirm/cancel is too flaky to\n"
        "                // gate on a second press -- a two-step confirm strands the\n"
        "                // player at the confirm cue (A intermittent, B dead). So\n"
        "                // complete on the single deliberate selection.\n"
        "                confirmDone = true;\n"
        "#else\n"
        "                if (key_is_down(k.confirm)) {\n"
        "                    confirmHoldTimer++;\n"
        "\n"
        "                    // Play progress sfx every 1/8 second (~8 frames)\n"
        "                    if (confirmHoldTimer % 8 == 0) {\n"
        "                        sfx(SFX_SHIFT2);\n"
        "                    }\n"
        "\n"
        "                    // Show zone meter progress sprite\n"
        "                    int progress = confirmHoldTimer * 12 / 60;\n"
        "                    if (progress > 12)\n"
        "                        progress = 12;\n"
        "\n"
        "                    int meterX =\n"
        "                        (savefile->settings.aspectRatio != 0) ? 191 : 204;\n"
        "                    sprite_set_attr(confirmMeterSprite, ShapeSquare, 2, 256 + 3,\n"
        "                                    12, 0);\n"
        "                    sprite_enable_mosaic(confirmMeterSprite);\n"
        "                    sprite_set_pos(confirmMeterSprite, meterX, 124);\n"
        "                    sprite_unhide(confirmMeterSprite, 0);\n"
        "\n"
        "                    for (int i = 0; i < 12; i++) {\n"
        "                        if (i < progress)\n"
        "                            setPaletteColor(12 + 16, 4 + i, 0x7fff, 1);\n"
        "                        else\n"
        "                            setPaletteColor(12 + 16, 4 + i, 0x0c63, 1);\n"
        "                    }\n"
        "\n"
        "                    // Action completes after 1 second (60 frames)\n"
        "                    if (confirmHoldTimer >= 60)\n"
        "                        confirmDone = true;\n"
        "                } else {\n"
        "                    // Button released, cancel hold\n"
        "                    confirmHoldTimer = 0;\n"
        "                    confirmHoldAction = -1;\n"
        "                    sprite_hide(confirmMeterSprite);\n"
        "                }\n"
        "#endif\n"
        "                if (confirmDone) {\n"
        "                    sprite_hide(confirmMeterSprite);\n"
        "                    if (confirmHoldAction == 1) {\n"
        "                        addGameStats();\n"
        "                        startGame();\n"
        "                        changeScene([]() { return new GameScene(); });\n"
        "                        paused = false;\n"
        "                        count = false;\n"
        "                        sfx(SFX_MENUCONFIRM);\n"
        "                        return 0;\n"
        "                    } else if (confirmHoldAction == 3) {\n"
        "                        enableBlend(prevBld);\n"
        "                        sfx(SFX_MENUCANCEL);\n"
        "                        buildBG(3, 0, 27, 0, 1, true);\n"
        "                        addGameStats();\n"
        "                        playSongRandom(0);\n"
        "\n"
        "#ifdef MULTIBOOT\n"
        "                        changeScene([]() { return new MultBattleScene(); },\n"
        "                                    Transitions::FADE);\n"
        "#else\n"
        "                        changeScene([]() { return new MainMenuScene(); },\n"
        "                                    Transitions::FADE);\n"
        "#endif\n"
        "                        return 1;\n"
        "                    }\n"
        "                }\n"
        "            } else if (key_hit(k.confirm)) {\n",
        1,
    ),
])

print("all patches generated")

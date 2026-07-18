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
    # no libdatachannel (WebRTC) on Apple mobile — NO_ONLINE
    (
        "    if host_machine.system() != 'emscripten' and host_machine.system() != 'horizon'\n"
        "        datachannel = dependency(",
        "    if host_machine.system() != 'emscripten' and host_machine.system() != 'horizon' and not apple_mobile\n"
        "        datachannel = dependency(",
        1,
    ),
    # platform defines: IOS instead of PC, no GL, online compiled out
    (
        "    elif host_machine.system() != 'emscripten'\n"
        "        add_project_arguments('-DPC', language: ['cpp', 'c'])\n",
        "    elif apple_mobile\n"
        "        add_project_arguments('-DIOS', language: ['cpp', 'c'])\n"
        "        add_project_arguments('-DNO_ONLINE', language: ['cpp', 'c'])\n"
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

print("all patches generated")

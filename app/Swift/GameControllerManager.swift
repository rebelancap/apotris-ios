import Foundation
import GameController

/// GCController + GCKeyboard → the game's packed-key input model.
/// Buttons map to SDL_GameControllerButton values (the in-game remap UI keeps
/// working); sticks feed upstream's synthetic analog keys with hysteresis
/// handled engine-side (deadzone in handleAnalogInputRaw).
final class GameControllerManager {
    static let shared = GameControllerManager()

    private var current: GCController?

    func activate() {
        NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect, object: nil, queue: .main
        ) { [weak self] note in
            self?.attach(note.object as? GCController)
        }
        NotificationCenter.default.addObserver(
            forName: .GCControllerDidDisconnect, object: nil, queue: .main
        ) { [weak self] _ in
            self?.attach(GCController.controllers().first)
        }
        NotificationCenter.default.addObserver(
            forName: .GCKeyboardDidConnect, object: nil, queue: .main
        ) { [weak self] note in
            self?.attachKeyboard((note.object as? GCKeyboard)?.keyboardInput)
        }
        attach(GCController.controllers().first)
        attachKeyboard(GCKeyboard.coalesced?.keyboardInput)
    }

    // MARK: - Gamepad

    private func attach(_ controller: GCController?) {
        current = controller
        HapticsManager.shared.attachController(controller)
        guard let pad = controller?.extendedGamepad else { return }

        let map: [(GCControllerButtonInput?, Int32)] = [
            (pad.buttonA, 0),                    // SDL_CONTROLLER_BUTTON_A
            (pad.buttonB, 1),                    // B
            (pad.buttonX, 2),                    // X
            (pad.buttonY, 3),                    // Y
            (pad.buttonOptions, 4),              // BACK (Select)
            (pad.buttonMenu, 6),                 // START
            (pad.leftThumbstickButton, 7),       // LEFTSTICK
            (pad.rightThumbstickButton, 8),      // RIGHTSTICK
            (pad.leftShoulder, 9),               // LEFTSHOULDER
            (pad.rightShoulder, 10),             // RIGHTSHOULDER
            (pad.dpad.up, 11),                   // DPAD_UP
            (pad.dpad.down, 12),                 // DPAD_DOWN
            (pad.dpad.left, 13),                 // DPAD_LEFT
            (pad.dpad.right, 14),                // DPAD_RIGHT
        ]
        for (button, sdl) in map {
            button?.pressedChangedHandler = { _, _, pressed in
                Bridge.key(sdl, down: pressed, type: ApotrisInputTypeController)
            }
        }

        pad.leftThumbstick.valueChangedHandler = { _, x, y in
            Bridge.analog(0, Int32(x * 32767))   // LEFTX
            Bridge.analog(1, Int32(-y * 32767))  // LEFTY (SDL: +down)
        }
        pad.rightThumbstick.valueChangedHandler = { _, x, y in
            Bridge.analog(2, Int32(x * 32767))
            Bridge.analog(3, Int32(-y * 32767))
        }
        pad.leftTrigger.valueChangedHandler = { _, v, _ in
            Bridge.analog(4, Int32(v * 32767))
        }
        pad.rightTrigger.valueChangedHandler = { _, v, _ in
            Bridge.analog(5, Int32(v * 32767))
        }
    }

    // MARK: - Hardware keyboard (matches liba_window desktop defaults)

    private static let keyMap: [GCKeyCode: Int32] = [
        .keyW: Int32(Character("w").asciiValue!),
        .keyA: Int32(Character("a").asciiValue!),
        .keyS: Int32(Character("s").asciiValue!),
        .keyD: Int32(Character("d").asciiValue!),
        .keyZ: Int32(Character("z").asciiValue!),
        .keyX: Int32(Character("x").asciiValue!),
        .keyC: Int32(Character("c").asciiValue!),
        .one: Int32(Character("1").asciiValue!),
        .two: Int32(Character("2").asciiValue!),
        .three: Int32(Character("3").asciiValue!),
        .returnOrEnter: 13,
        .escape: 27,
        .deleteOrBackspace: 8,
        .spacebar: 32,
        .upArrow: Int32(bitPattern: UInt32(82) | (1 << 30)),
        .downArrow: Int32(bitPattern: UInt32(81) | (1 << 30)),
        .leftArrow: Int32(bitPattern: UInt32(80) | (1 << 30)),
        .rightArrow: Int32(bitPattern: UInt32(79) | (1 << 30)),
        .leftShift: Int32(bitPattern: UInt32(225) | (1 << 30)),
    ]

    private func attachKeyboard(_ input: GCKeyboardInput?) {
        input?.keyChangedHandler = { _, _, keyCode, pressed in
            guard let sdl = Self.keyMap[keyCode] else { return }
            Bridge.key(sdl, down: pressed, type: ApotrisInputTypeKeyboard)
        }
    }
}

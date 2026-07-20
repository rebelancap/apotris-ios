import Foundation
import GameController
import QuartzCore

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
        guard let pad = controller?.extendedGamepad else {
            stopPolling()
            return
        }

        // Poll buttons + d-pad every frame instead of using pressedChangedHandler:
        // on visionOS the per-event delivery drops presses/releases (B never
        // arrives; a missed D-pad release strands the direction as held -> DAS
        // auto-repeat). Polling reads the true current state each frame, robust
        // to dropped events. (quake3e's ios_input.m polls GCController for the
        // same reason.) Sticks/triggers stay event-driven since they're analog.
        startPolling()

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

    // Frame-synced polling of the pad's digital inputs (see attach()).
    private var pollLink: CADisplayLink?
    private var padState: [Int32: Bool] = [:]

    private func startPolling() {
        guard pollLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(pollPad))
        link.add(to: .main, forMode: .common)
        pollLink = link
    }

    private func stopPolling() {
        pollLink?.invalidate()
        pollLink = nil
        for (sdl, pressed) in padState where pressed {
            Self.recordDiag(sdl, pressed: false)
            Bridge.key(sdl, down: false, type: ApotrisInputTypeController)
        }
        padState.removeAll()
    }

    @objc private func pollPad() {
        guard let pad = current?.extendedGamepad else { return }
        // Left stick doubles as the d-pad — the analog->synthetic-key path isn't
        // wired for iOS, so the stick was dead in menus and gameplay. A direction
        // fires if the d-pad OR the stick (past a 0.5 deadzone) calls for it.
        let lx = pad.leftThumbstick.xAxis.value
        let ly = pad.leftThumbstick.yAxis.value
        let states: [(Int32, Bool)] = [
            (0, pad.buttonA.isPressed),
            (1, pad.buttonB.isPressed),
            (2, pad.buttonX.isPressed),
            (3, pad.buttonY.isPressed),
            (4, pad.buttonOptions?.isPressed ?? false),
            (6, pad.buttonMenu.isPressed),
            (7, pad.leftThumbstickButton?.isPressed ?? false),
            (8, pad.rightThumbstickButton?.isPressed ?? false),
            (9, pad.leftShoulder.isPressed),
            (10, pad.rightShoulder.isPressed),
            (11, pad.dpad.up.isPressed || ly > 0.5),
            (12, pad.dpad.down.isPressed || ly < -0.5),
            (13, pad.dpad.left.isPressed || lx < -0.5),
            (14, pad.dpad.right.isPressed || lx > 0.5),
        ]
        for (sdl, pressed) in states where padState[sdl] != pressed {
            padState[sdl] = pressed
            Self.recordDiag(sdl, pressed: pressed)
            Bridge.key(sdl, down: pressed, type: ApotrisInputTypeController)
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

    // MARK: - Diagnostics (shown in the debug HUD; helps chase visionOS pad
    // delivery — e.g. does B arrive at all, does the D-pad release fire).
    static var lastEvent = "-"
    static var held: Set<Int32> = []
    private static func recordDiag(_ sdl: Int32, pressed: Bool) {
        if pressed { held.insert(sdl) } else { held.remove(sdl) }
        lastEvent = "\(buttonName(sdl))\(pressed ? "v" : "^")"
    }
    static func buttonName(_ sdl: Int32) -> String {
        switch sdl {
        case 0: return "A"; case 1: return "B"; case 2: return "X"; case 3: return "Y"
        case 4: return "Sel"; case 6: return "Start"; case 9: return "LB"; case 10: return "RB"
        case 11: return "Up"; case 12: return "Dn"; case 13: return "Lf"; case 14: return "Rt"
        default: return "b\(sdl)"
        }
    }
    // Bumped by VisionGestureLayer on each new spatial (gaze-pinch) event. After
    // the gamepad claim, pressing A while gazing at the game must NOT bump this
    // (A goes via GCController, not the gaze path) — the exclusive-delivery check.
    static var spatialEvents = 0
    static var debugString: String {
        let conn = GCController.controllers().first != nil
        let heldStr = held.isEmpty ? "-"
            : held.sorted().map { buttonName($0) }.joined(separator: "+")
        return "GC:\(conn ? "y" : "n") last:\(lastEvent) held:\(heldStr) sp:\(spatialEvents)"
    }
}

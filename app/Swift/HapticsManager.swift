import CoreHaptics
import Foundation
import GameController
#if canImport(UIKit)
import UIKit
#endif

/// One place for every buzz. Gesture cues + GB button presses use the
/// UIFeedbackGenerator family (cheap, latency-tuned); the engine's rumble
/// path drives a continuous CoreHaptics player on the controller when one is
/// attached, else on the device. Everything respects the master toggle.
final class HapticsManager {
    static let shared = HapticsManager()

    var enabled = true

    #if os(iOS)
    private let impactLight = UIImpactFeedbackGenerator(style: .light)
    private let impactRigid = UIImpactFeedbackGenerator(style: .rigid)
    private let impactMedium = UIImpactFeedbackGenerator(style: .medium)
    private let selection = UISelectionFeedbackGenerator()
    #endif

    private var deviceEngine: CHHapticEngine?
    private var devicePlayer: CHHapticPatternPlayer?
    private var controllerEngine: CHHapticEngine?
    private var controllerPlayer: CHHapticPatternPlayer?

    func activate() {
        #if os(iOS)
        impactLight.prepare()
        selection.prepare()
        if CHHapticEngine.capabilitiesForHardware().supportsHaptics {
            deviceEngine = try? CHHapticEngine()
            try? deviceEngine?.start()
        }
        #endif

        apotris_set_rumble_handler { strength in
            HapticsManager.shared.rumble(strength)
        }
    }

    func attachController(_ controller: GCController?) {
        controllerEngine?.stop()
        controllerEngine = nil
        controllerPlayer = nil
        guard let haptics = controller?.haptics else { return }
        controllerEngine = haptics.createEngine(withLocality: .default)
        try? controllerEngine?.start()
    }

    // MARK: - Discrete cues

    func gestureCue(_ cue: GestureEngine.HapticCue) {
        guard enabled else { return }
        #if os(iOS)
        switch cue {
        case .step: selection.selectionChanged()
        case .rotate: impactLight.impactOccurred(intensity: 0.7)
        case .hardDrop: impactRigid.impactOccurred()
        case .hold: impactLight.impactOccurred()
        case .chord: impactMedium.impactOccurred(intensity: 0.8)
        }
        #endif
    }

    func buttonDown() {
        guard enabled else { return }
        #if os(iOS)
        impactLight.impactOccurred(intensity: 0.8)
        #endif
    }

    func buttonUp() {
        guard enabled else { return }
        #if os(iOS)
        impactLight.impactOccurred(intensity: 0.4)
        #endif
    }

    func dpadChanged() {
        guard enabled else { return }
        #if os(iOS)
        selection.selectionChanged()
        #endif
    }

    // MARK: - Engine rumble (called from the game thread!)

    private func rumble(_ strength: UInt16) {
        DispatchQueue.main.async { [self] in
            guard enabled else { return }
            let engine = controllerEngine ?? deviceEngine
            guard let engine else { return }
            if strength == 0 {
                try? (controllerEngine != nil ? controllerPlayer : devicePlayer)?
                    .stop(atTime: 0)
                return
            }
            let intensity = min(1.0, Float(strength) / 8.0)
            let event = CHHapticEvent(
                eventType: .hapticContinuous,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity,
                                           value: intensity),
                    CHHapticEventParameter(parameterID: .hapticSharpness,
                                           value: 0.4),
                ],
                relativeTime: 0,
                duration: 0.08)
            if let pattern = try? CHHapticPattern(events: [event], parameters: []),
               let player = try? engine.makePlayer(with: pattern) {
                if controllerEngine != nil {
                    controllerPlayer = player
                } else {
                    devicePlayer = player
                }
                try? player.start(atTime: 0)
            }
        }
    }
}

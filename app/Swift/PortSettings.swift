import SwiftUI

enum ControlScheme: String, CaseIterable, Identifiable {
    case gestures
    case buttons
    case both

    var id: String { rawValue }

    var label: String {
        switch self {
        case .gestures: return "Gestures"
        case .buttons: return "GB Buttons"
        case .both: return "Both"
        }
    }

    var showsButtons: Bool { self != .gestures }
    var acceptsGestures: Bool { self != .buttons }
}

enum DisplayFilter: Int, CaseIterable, Identifiable {
    case sharp = 0
    case lcd = 1
    case crt = 2

    var id: Int { rawValue }
    var label: String {
        switch self {
        case .sharp: return "Sharp"
        case .lcd: return "LCD"
        case .crt: return "CRT"
        }
    }
}

/// What happens to Apotris's sound when another app is already playing.
/// Mirrors `ApotrisAudioMode` in AppBridge.h — raw values must match.
enum AudioMode: Int, CaseIterable, Identifiable {
    case stopOthers = 0
    case playBoth = 1
    case duckOthers = 2
    case duckGame = 3
    case muteGame = 4

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .stopOthers: return "Stop Other Audio"
        case .playBoth: return "Play Both"
        case .duckOthers: return "Lower Other Audio"
        case .duckGame: return "Lower Game Audio"
        case .muteGame: return "Mute Game Audio"
        }
    }

    /// A sentence, not a four-word label — "duck" and "mix" mean nothing to a
    /// player.
    var detail: String {
        switch self {
        case .stopOthers: return "Music and podcasts stop when Apotris starts."
        case .playBoth: return "Both play together, neither one quieter."
        case .duckOthers:
            return "Music and podcasts drop to the background; game audio stays full."
        case .duckGame:
            return "Game audio drops to the background while another app is playing."
        case .muteGame:
            return "Game audio goes silent while another app is playing."
        }
    }
}

final class PortSettings: ObservableObject {
    @AppStorage("controlScheme") var schemeRaw: String = ControlScheme.gestures.rawValue
    @AppStorage("displayFilter") var filterRaw: Int = DisplayFilter.sharp.rawValue
    @AppStorage("hapticsEnabled") var hapticsEnabled: Bool = true
    @AppStorage("gestureSensitivity") var sensitivity: Double = 1.0
    @AppStorage("buttonOpacity") var buttonOpacity: Double = 0.55
    @AppStorage("buttonScale") var buttonScale: Double = 1.0
    @AppStorage("showChips") var showChips: Bool = true
    @AppStorage("showDebugHUD") var showDebugHUD: Bool = false
    // Read straight from UserDefaults by apotris_audio_boot() before the game
    // thread starts — defaults here must match the C side's.
    @AppStorage("audioMode") var audioModeRaw: Int = AudioMode.duckOthers.rawValue
    @AppStorage("gameVolume") var gameVolume: Double = 1.0

    var scheme: ControlScheme {
        get { ControlScheme(rawValue: schemeRaw) ?? .gestures }
        set {
            schemeRaw = newValue.rawValue
            objectWillChange.send()
        }
    }

    var audioMode: AudioMode {
        get { AudioMode(rawValue: audioModeRaw) ?? .duckOthers }
        set {
            audioModeRaw = newValue.rawValue
            Bridge.setAudioMode(newValue.rawValue)
            objectWillChange.send()
        }
    }
}

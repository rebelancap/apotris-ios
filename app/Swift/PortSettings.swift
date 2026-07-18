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

final class PortSettings: ObservableObject {
    @AppStorage("controlScheme") var schemeRaw: String = ControlScheme.gestures.rawValue
    @AppStorage("displayFilter") var filterRaw: Int = DisplayFilter.sharp.rawValue
    @AppStorage("hapticsEnabled") var hapticsEnabled: Bool = true
    @AppStorage("gestureSensitivity") var sensitivity: Double = 1.0
    @AppStorage("buttonOpacity") var buttonOpacity: Double = 0.55
    @AppStorage("buttonScale") var buttonScale: Double = 1.0
    @AppStorage("showChips") var showChips: Bool = true
    @AppStorage("showDebugHUD") var showDebugHUD: Bool = false

    var scheme: ControlScheme {
        get { ControlScheme(rawValue: schemeRaw) ?? .gestures }
        set {
            schemeRaw = newValue.rawValue
            objectWillChange.send()
        }
    }
}

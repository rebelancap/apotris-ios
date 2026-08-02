import Foundation

/// Thin Swift face over the C bridge (AppBridge.h via the bridging header).
enum Bridge {
    static func startGame() {
        let resources = Bundle.main.resourcePath ?? "."
        let documents = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        )[0].path
        apotris_start(resources, documents)
    }

    static var inGameplay: Bool { apotris_in_gameplay() }

    static func pulse(_ action: ApotrisAction) { apotris_action_pulse(action) }

    static func hold(_ action: ApotrisAction, _ down: Bool) {
        apotris_action_event(action, down)
    }

    static func key(_ rawKey: Int32, down: Bool, type: ApotrisInputType) {
        apotris_key_event(rawKey, down, type)
    }

    static func analog(_ axis: Int32, _ value: Int32) {
        apotris_analog_event(axis, value)
    }

    static func setAudioMode(_ mode: Int) { apotris_audio_set_mode(Int32(mode)) }
    static func setGameVolume(_ volume: Double) {
        apotris_audio_set_volume(Float(volume))
    }

    static func setBackground(_ flag: Bool) { apotris_set_background(flag) }
    static func requestSave() { apotris_request_save() }

    static var debugState: String {
        guard let s = apotris_debug_state() else { return "" }
        return String(cString: s)
    }
}

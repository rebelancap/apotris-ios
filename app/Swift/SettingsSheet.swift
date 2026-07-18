import SwiftUI

/// Port-level settings (control scheme, haptics, sensitivity). Game settings
/// (skins, audio, DAS/ARR, remapping…) live in Apotris's own menus.
struct SettingsSheet: View {
    @EnvironmentObject var settings: PortSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Controls") {
                    Picker("Scheme", selection: Binding(
                        get: { settings.scheme },
                        set: { settings.scheme = $0 }
                    )) {
                        ForEach(ControlScheme.allCases) { scheme in
                            Text(scheme.label).tag(scheme)
                        }
                    }
                    .pickerStyle(.segmented)

                    if settings.scheme.acceptsGestures {
                        VStack(alignment: .leading) {
                            Text("Gesture sensitivity")
                            Slider(value: $settings.sensitivity, in: 0.6...1.6)
                        }
                    }

                    if settings.scheme.showsButtons {
                        VStack(alignment: .leading) {
                            Text("Button opacity")
                            Slider(value: $settings.buttonOpacity, in: 0.2...1.0)
                        }
                        VStack(alignment: .leading) {
                            Text("Button size")
                            Slider(value: $settings.buttonScale, in: 0.8...1.4)
                        }
                    }
                }

                Section("Display") {
                    Picker("Filter", selection: $settings.filterRaw) {
                        ForEach(DisplayFilter.allCases) { f in
                            Text(f.label).tag(f.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text("Sharp is crisp pixels; LCD adds a handheld pixel grid; CRT adds scanlines.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Feedback") {
                    Toggle("Haptics", isOn: $settings.hapticsEnabled)
                }

                Section("Interface") {
                    Toggle("Pause & settings chips", isOn: $settings.showChips)
                    Toggle("Debug HUD", isOn: $settings.showDebugHUD)
                }

                Section {
                    Text("Gestures — drag: move · flick down: hard drop · drag down: soft drop · tap right/left: rotate · two-finger tap: 180 · swipe up: hold · long-press: zone. In menus: tap = confirm, two-finger = back, swipes navigate.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Apotris")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

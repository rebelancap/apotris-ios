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

                Section("Gestures — gameplay") {
                    Group {
                        LabeledContent("Drag ← →", value: "Move")
                        LabeledContent("Drag ↓", value: "Soft drop")
                        LabeledContent("Flick ↓", value: "Hard drop")
                        LabeledContent("Tap left / right", value: "Rotate ↺ / ↻")
                        LabeledContent("Two-finger tap", value: "Rotate 180°")
                        LabeledContent("Swipe ↑", value: "Hold")
                        LabeledContent("Long-press", value: "Zone")
                    }
                    .font(.footnote)
                }
                Section("Gestures — menus") {
                    Group {
                        LabeledContent("Tap", value: "Confirm")
                        LabeledContent("Two-finger tap", value: "Back")
                        LabeledContent("Swipe", value: "Navigate")
                    }
                    .font(.footnote)
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

import SwiftUI
#if os(visionOS)
import GameController
#endif

struct MetalHostView: UIViewRepresentable {
    var filter: Int
    func makeUIView(context: Context) -> ApotrisMetalView {
        let view = ApotrisMetalView(frame: .zero)
        view.setFilterMode(filter)
        return view
    }
    func updateUIView(_ view: ApotrisMetalView, context: Context) {
        view.setFilterMode(filter)
    }
}

struct GameScreen: View {
    @EnvironmentObject var settings: PortSettings
    @State private var showSettings = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            MetalHostView(filter: settings.filterRaw)
                .ignoresSafeArea()

            #if os(visionOS)
            VisionGestureLayer()
                .ignoresSafeArea()
            #else
            if settings.scheme.acceptsGestures {
                GestureOverlay()
                    .ignoresSafeArea()
            }

            if settings.scheme.showsButtons {
                GBButtonsView()
                    .ignoresSafeArea(edges: .bottom)
            }
            #endif

            VStack(spacing: 6) {
                HStack {
                    Spacer()
                    if settings.showChips {
                        HUDChip(systemName: "pause.fill") {
                            Bridge.pulse(ApotrisActionPause)
                        }
                        .accessibilityIdentifier("chipPause")
                        HUDChip(systemName: "gearshape.fill") {
                            showSettings = true
                        }
                        .accessibilityIdentifier("chipSettings")
                    }
                }
                .padding(.trailing, 12)
                .padding(.top, 4)
                #if os(iOS)
                GameInfoBar()
                #endif
                Spacer()
                if settings.showDebugHUD {
                    DebugHUD()
                        .padding(.bottom, 4)
                }
            }
        }
        #if os(visionOS)
        // Claim the gamepad at the ROOT of the window content. GCEventInteraction
        // is scoped to the gaze/hit-test target's subtree, not app-wide — a claim
        // on a 1pt corner view never applies because nobody gazes there. This
        // routes controller-sourced events to GCController while hand gaze-pinch
        // still flows to VisionGestureLayer (the claim filters by source). The
        // settings sheet + ornament are separate hierarchies, so A still
        // gaze-clicks the chrome. (visionOS 2.0+; per Fable consult 2026-07-19.)
        .handlesGameControllerEvents(matching: .gamepad)
        #endif
        .sheet(isPresented: $showSettings) {
            SettingsSheet()
                .environmentObject(settings)
        }
        // No visionOS ornament: it competed with the window's grab/close chrome
        // and users rely on gestures + the on-screen chips instead.
    }
}

struct HUDChip: View {
    let systemName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 50, height: 38)
                .background(.black.opacity(0.45), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct DebugHUD: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            Text(Bridge.debugState + "\n" + GameControllerManager.debugString)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.green)
                .padding(4)
                .background(.black.opacity(0.6))
                .accessibilityIdentifier("debugHUD")
        }
    }
}

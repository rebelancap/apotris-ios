import SwiftUI

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
        .sheet(isPresented: $showSettings) {
            SettingsSheet()
                .environmentObject(settings)
        }
        #if os(visionOS)
        .ornament(attachmentAnchor: .scene(.bottom), contentAlignment: .top) {
            HStack(spacing: 14) {
                OrnamentButton("pause.fill") { Bridge.pulse(ApotrisActionPause) }
                OrnamentButton("tray.and.arrow.down.fill") {
                    Bridge.pulse(ApotrisActionHold)
                }
                OrnamentButton("arrow.counterclockwise") {
                    Bridge.pulse(ApotrisActionRotateCCW)
                }
                OrnamentButton("arrow.clockwise") {
                    Bridge.pulse(ApotrisActionRotateCW)
                }
                OrnamentButton("gearshape.fill") { showSettings = true }
            }
            .padding(12)
            .glassBackgroundEffect()
            // Transparent gap above the glass so the bar clears the window
            // edge instead of overlapping it.
            .padding(.top, 28)
        }
        #endif
    }
}

struct HUDChip: View {
    let systemName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 34, height: 26)
                .background(.black.opacity(0.35), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct DebugHUD: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            Text(Bridge.debugState)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.green)
                .padding(4)
                .background(.black.opacity(0.6))
                .accessibilityIdentifier("debugHUD")
        }
    }
}

#if os(visionOS)
struct OrnamentButton: View {
    let systemName: String
    let action: () -> Void

    init(_ systemName: String, action: @escaping () -> Void) {
        self.systemName = systemName
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 20, weight: .semibold))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.borderless)
    }
}
#endif

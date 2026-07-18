#if os(iOS)
import SwiftUI

/// Native top HUD for iOS portrait. The engine's side-info columns are hidden
/// (see the nativeHud gate) so the board can zoom bigger; these values are
/// read from the bridge and shown here instead.
struct GameInfoBar: View {
    @State private var hud = ApotrisHud()
    private let tick = Timer.publish(every: 1.0 / 20.0, on: .main, in: .common)
        .autoconnect()

    var body: some View {
        Group {
            if apotris_native_hud() && hud.valid != 0 {
                HStack(alignment: .firstTextBaseline, spacing: 18) {
                    Text(cstr(hud.mode))
                        .font(.system(size: 17, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                    if hud.showTime != 0 { stat("TIME", cstr(hud.time)) }
                    if hud.showScore != 0 { stat("SCORE", "\(hud.score)") }
                    if hud.showLevel != 0 { stat("LEVEL", "\(hud.level)") }
                    if hud.showLines != 0 { stat("LINES", "\(hud.lines)") }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.black.opacity(0.32), in: Capsule())
                .shadow(color: .black.opacity(0.35), radius: 4, y: 1)
            }
        }
        .onReceive(tick) { _ in apotris_hud(&hud) }
        .animation(.none, value: hud.score)
        .allowsHitTesting(false) // never intercept a gesture over the board
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 1) {
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
            Text(value)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .monospacedDigit()
        }
    }
}

/// Read a fixed C `char[]` field (imported as a tuple) into a Swift String.
private func cstr<T>(_ tuple: T) -> String {
    withUnsafePointer(to: tuple) {
        $0.withMemoryRebound(to: CChar.self,
                             capacity: MemoryLayout<T>.size) {
            String(cString: $0)
        }
    }
}
#endif

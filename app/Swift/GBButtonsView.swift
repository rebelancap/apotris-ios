import SwiftUI

/// Optional AGB-flavored on-screen controls (a setting — default is pure
/// gestures). Buttons inject raw SDL controller-button values as a virtual
/// gamepad, so the game's own remapping applies. Haptics on press/release,
/// d-pad supports sliding between directions without lifting.
struct GBButtonsView: View {
    @EnvironmentObject var settings: PortSettings

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            let scale = CGFloat(settings.buttonScale)

            ZStack {
                // D-pad, lower-left
                DPadView()
                    .frame(width: 132 * scale, height: 132 * scale)
                    .position(x: 24 + 66 * scale,
                              y: geo.size.height - (landscape ? 30 : 60) - 66 * scale)

                // A / B pair, lower-right (A above-right, B below-left, GBA style)
                GBRoundButton(label: "A", sdlButton: 0)
                    .frame(width: 62 * scale, height: 62 * scale)
                    .position(x: geo.size.width - 24 - 31 * scale,
                              y: geo.size.height - (landscape ? 30 : 60) - 96 * scale)
                GBRoundButton(label: "B", sdlButton: 1)
                    .frame(width: 62 * scale, height: 62 * scale)
                    .position(x: geo.size.width - 24 - 31 * scale - 66 * scale,
                              y: geo.size.height - (landscape ? 30 : 60) - 40 * scale)

                // L / R shoulders at the top corners of the control zone
                GBPillButton(label: "L", sdlButton: 9)
                    .frame(width: 76 * scale, height: 30 * scale)
                    .position(x: 24 + 38 * scale,
                              y: geo.size.height - (landscape ? 30 : 60) - 168 * scale)
                GBPillButton(label: "R", sdlButton: 10)
                    .frame(width: 76 * scale, height: 30 * scale)
                    .position(x: geo.size.width - 24 - 38 * scale,
                              y: geo.size.height - (landscape ? 30 : 60) - 168 * scale)

                // Start / Select, bottom center
                HStack(spacing: 18 * scale) {
                    GBPillButton(label: "SELECT", sdlButton: 4, small: true)
                        .frame(width: 64 * scale, height: 20 * scale)
                    GBPillButton(label: "START", sdlButton: 6, small: true)
                        .frame(width: 64 * scale, height: 20 * scale)
                }
                .position(x: geo.size.width / 2,
                          y: geo.size.height - (landscape ? 14 : 30))
            }
            .opacity(settings.buttonOpacity)
        }
        .allowsHitTesting(true)
    }
}

// MARK: - Round face button

struct GBRoundButton: View {
    let label: String
    let sdlButton: Int32
    @GestureState private var pressed = false

    var body: some View {
        Circle()
            .fill(Color(red: 0.42, green: 0.31, blue: 0.62))
            .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1.5))
            .overlay(
                Text(label)
                    .font(.system(size: 22, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
            )
            .scaleEffect(pressed ? 0.92 : 1.0)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($pressed) { _, state, _ in state = true }
            )
            .onChange(of: pressed) { _, down in
                Bridge.key(sdlButton, down: down, type: ApotrisInputTypeTouch)
                if down {
                    HapticsManager.shared.buttonDown()
                } else {
                    HapticsManager.shared.buttonUp()
                }
            }
            .accessibilityIdentifier("gbButton\(label)")
    }
}

// MARK: - Pill button (shoulders + start/select)

struct GBPillButton: View {
    let label: String
    let sdlButton: Int32
    var small = false
    @GestureState private var pressed = false

    var body: some View {
        Capsule()
            .fill(Color(white: 0.28))
            .overlay(Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 1.2))
            .overlay(
                Text(label)
                    .font(.system(size: small ? 10 : 15, weight: .bold,
                                  design: .rounded))
                    .foregroundStyle(.white.opacity(0.8))
            )
            .scaleEffect(pressed ? 0.94 : 1.0)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($pressed) { _, state, _ in state = true }
            )
            .onChange(of: pressed) { _, down in
                Bridge.key(sdlButton, down: down, type: ApotrisInputTypeTouch)
                if down {
                    HapticsManager.shared.buttonDown()
                } else {
                    HapticsManager.shared.buttonUp()
                }
            }
            .accessibilityIdentifier("gbButton\(label)")
    }
}

// MARK: - D-pad (8-way, slide between directions, selection ticks)

struct DPadView: View {
    // Raw SDL buttons: up 11, down 12, left 13, right 14
    @State private var active: Set<Int32> = []

    var body: some View {
        GeometryReader { geo in
            let size = geo.size.width
            ZStack {
                DPadShape()
                    .fill(Color(white: 0.22))
                    .overlay(DPadShape().stroke(.white.opacity(0.25), lineWidth: 1.5))
                ForEach([(0, -1, "arrowtriangle.up.fill"),
                         (0, 1, "arrowtriangle.down.fill"),
                         (-1, 0, "arrowtriangle.left.fill"),
                         (1, 0, "arrowtriangle.right.fill")], id: \.2) { dx, dy, icon in
                    Image(systemName: icon)
                        .font(.system(size: size * 0.10, weight: .black))
                        .foregroundStyle(.white.opacity(0.5))
                        .position(x: size / 2 + CGFloat(dx) * size * 0.33,
                                  y: size / 2 + CGFloat(dy) * size * 0.33)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        update(point: value.location, size: size)
                    }
                    .onEnded { _ in
                        setActive([])
                    }
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("D-pad")
        .accessibilityIdentifier("gbDpad")
    }

    private func update(point: CGPoint, size: CGFloat) {
        let cx = point.x - size / 2
        let cy = point.y - size / 2
        let r = hypot(cx, cy)
        guard r > size * 0.12 else {
            setActive([])
            return
        }
        var next: Set<Int32> = []
        let angle = atan2(cy, cx) // 0 = right, positive = down
        let deg = angle * 180 / .pi
        // 8 sectors of 45°; diagonals press two buttons.
        switch deg {
        case -22.5..<22.5: next = [14]
        case 22.5..<67.5: next = [14, 12]
        case 67.5..<112.5: next = [12]
        case 112.5..<157.5: next = [13, 12]
        case -67.5 ..< -22.5: next = [14, 11]
        case -112.5 ..< -67.5: next = [11]
        case -157.5 ..< -112.5: next = [13, 11]
        default: next = [13]
        }
        setActive(next)
    }

    private func setActive(_ next: Set<Int32>) {
        guard next != active else { return }
        for b in active.subtracting(next) {
            Bridge.key(b, down: false, type: ApotrisInputTypeTouch)
        }
        for b in next.subtracting(active) {
            Bridge.key(b, down: true, type: ApotrisInputTypeTouch)
        }
        if !next.isEmpty {
            HapticsManager.shared.dpadChanged()
        }
        active = next
    }
}

struct DPadShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let arm = w * 0.34
        let off = (w - arm) / 2
        var p = Path()
        p.addRoundedRect(in: CGRect(x: off, y: 0, width: arm, height: w),
                         cornerSize: CGSize(width: 6, height: 6))
        p.addRoundedRect(in: CGRect(x: 0, y: off, width: w, height: arm),
                         cornerSize: CGSize(width: 6, height: 6))
        return p
    }
}

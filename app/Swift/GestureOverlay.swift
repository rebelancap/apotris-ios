#if os(iOS)
import SwiftUI
import UIKit

/// Transparent full-screen UIView that feeds raw touches to the GestureEngine.
final class GestureOverlayUIView: UIView {
    let engine: GestureEngine

    init(engine: GestureEngine) {
        self.engine = engine
        super.init(frame: .zero)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        engine.viewWidth = bounds.width
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            engine.touchBegan(ObjectIdentifier(t), at: t.location(in: self),
                              time: t.timestamp)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            // Coalesced touches preserve the full 120 Hz sample stream for
            // the flick classifier.
            let seq = event?.coalescedTouches(for: t) ?? [t]
            for c in seq {
                engine.touchMoved(ObjectIdentifier(t), at: c.location(in: self),
                                  time: c.timestamp)
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            engine.touchEnded(ObjectIdentifier(t), at: t.location(in: self),
                              time: t.timestamp)
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            engine.touchCancelled(ObjectIdentifier(t))
        }
    }
}

struct GestureOverlay: UIViewRepresentable {
    @EnvironmentObject var settings: PortSettings

    func makeUIView(context: Context) -> GestureOverlayUIView {
        let engine = GestureEngine()
        engine.isGameplay = { Bridge.inGameplay }
        engine.onPulse = { Bridge.pulse($0) }
        engine.onHold = { Bridge.hold($0, $1) }
        engine.onHaptic = { HapticsManager.shared.gestureCue($0) }
        return GestureOverlayUIView(engine: engine)
    }

    func updateUIView(_ view: GestureOverlayUIView, context: Context) {
        view.engine.config.sensitivity = CGFloat(settings.sensitivity)
        HapticsManager.shared.enabled = settings.hapticsEnabled
    }
}
#endif

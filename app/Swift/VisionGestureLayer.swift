#if os(visionOS)
import SwiftUI

/// visionOS input: SpatialEventGesture feeds the same GestureEngine the
/// iPhone uses. Chirality drives rotation (right pinch-tap = CW, left = CCW,
/// left tap in menus = back); drags/flicks share the iOS classifier with
/// indirect-friendly thresholds. Direct touch (poking the window) arrives
/// through the same gesture and behaves identically.
struct VisionGestureLayer: View {
    @EnvironmentObject var settings: PortSettings
    @State private var engine: GestureEngine = {
        let e = GestureEngine()
        e.config.cellPt = 28        // indirect pinch gain differs from touch
        e.config.flickVy = 600
        e.config.flickMinPt = 30
        e.config.menuStepPt = 48
        e.isGameplay = { Bridge.inGameplay }
        e.onPulse = { Bridge.pulse($0) }
        e.onHold = { Bridge.hold($0, $1) }
        e.onHaptic = { _ in } // no touch haptics on visionOS
        return e
    }()
    @State private var activeEvents: Set<AnyHashable> = []

    var body: some View {
        GeometryReader { geo in
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    SpatialEventGesture(coordinateSpace: .local)
                        .onChanged { events in
                            engine.viewWidth = geo.size.width
                            let now = Date().timeIntervalSinceReferenceDate
                            for event in events {
                                let id = AnyHashable(event.id)
                                let hand: Int
                                switch event.chirality {
                                case .right: hand = 1
                                case .left: hand = -1
                                default: hand = 0
                                }
                                switch event.phase {
                                case .active:
                                    if activeEvents.contains(id) {
                                        engine.touchMoved(id, at: event.location,
                                                          time: now)
                                    } else {
                                        activeEvents.insert(id)
                                        // diagnostic: a claimed pad's A must not
                                        // arrive here (it goes via GCController).
                                        GameControllerManager.spatialEvents += 1
                                        engine.touchBegan(id, at: event.location,
                                                          time: now, hand: hand)
                                    }
                                case .ended:
                                    activeEvents.remove(id)
                                    engine.touchEnded(id, at: event.location,
                                                      time: now)
                                case .cancelled:
                                    activeEvents.remove(id)
                                    engine.touchCancelled(id)
                                @unknown default:
                                    break
                                }
                            }
                        }
                        .onEnded { events in
                            let now = Date().timeIntervalSinceReferenceDate
                            for event in events {
                                let id = AnyHashable(event.id)
                                guard activeEvents.contains(id) else { continue }
                                activeEvents.remove(id)
                                if event.phase == .cancelled {
                                    engine.touchCancelled(id)
                                } else {
                                    engine.touchEnded(id, at: event.location,
                                                      time: now)
                                }
                            }
                        }
                )
                .onChange(of: settings.sensitivity) { _, v in
                    engine.config.sensitivity = CGFloat(v)
                }
        }
    }
}
#endif

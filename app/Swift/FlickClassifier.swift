import CoreGraphics
import Foundation

/// Decides hard drop (flick) vs soft drop (drag) on a vertically-locked
/// downward gesture. Pure logic — unit-tested with synthetic traces.
///
/// Spec (docs/controls.md): decide within `windowMs` of vertical lock.
/// Hard drop fires the moment instantaneous downward velocity ≥ `flickVy`
/// AND net dy ≥ `flickMinPt` inside the window. After the window closes the
/// gesture can only be a soft drop (misclassification cost is asymmetric —
/// an accidental hard drop ruins a game).
struct FlickClassifier {
    enum Verdict: Equatable {
        case undecided
        case hardDrop
        case softDrop
    }

    struct Sample {
        var time: TimeInterval
        var y: CGFloat
    }

    var windowMs: Double = 120
    var flickVy: CGFloat = 900
    var flickMinPt: CGFloat = 36
    var softEngagePt: CGFloat = 20

    private(set) var verdict: Verdict = .undecided
    private var samples: [Sample] = []
    private var startTime: TimeInterval = 0
    private var startY: CGFloat = 0
    private var windowClosed = false

    mutating func begin(time: TimeInterval, y: CGFloat) {
        verdict = .undecided
        samples = [Sample(time: time, y: y)]
        startTime = time
        startY = y
        windowClosed = false
    }

    /// Feed a movement sample; returns the verdict after this sample.
    /// `.hardDrop` is terminal. `.softDrop` means "engage soft drop now"
    /// (also terminal for classification; the caller keeps the key held).
    @discardableResult
    mutating func addSample(time: TimeInterval, y: CGFloat) -> Verdict {
        guard verdict == .undecided else { return verdict }

        samples.append(Sample(time: time, y: y))
        if samples.count > 8 {
            samples.removeFirst(samples.count - 8)
        }

        let netDy = y - startY
        let elapsed = (time - startTime) * 1000.0

        if elapsed <= windowMs {
            // Instantaneous velocity over the trailing ~30 ms.
            let cutoff = time - 0.030
            let base = samples.first(where: { $0.time >= cutoff }) ?? samples[0]
            let dt = time - base.time
            if dt > 0.001 {
                let vy = (y - base.y) / CGFloat(dt)
                if vy >= flickVy && netDy >= flickMinPt {
                    verdict = .hardDrop
                    return verdict
                }
            }
        } else {
            windowClosed = true
        }

        if netDy >= softEngagePt && (windowClosed || netDy > 0) {
            // Past the window (or clearly a controlled drag): soft drop.
            if windowClosed || elapsed > windowMs {
                verdict = .softDrop
            } else if netDy >= softEngagePt && velocityBelowFlick(time: time, y: y) {
                // Inside the window but moving slowly — commit to soft early
                // so the drop starts responding without the full 120 ms wait.
                verdict = .softDrop
            }
        }
        return verdict
    }

    private func velocityBelowFlick(time: TimeInterval, y: CGFloat) -> Bool {
        let cutoff = time - 0.030
        guard let base = samples.first(where: { $0.time >= cutoff }),
              time - base.time > 0.001 else { return false }
        let vy = (y - base.y) / CGFloat(time - base.time)
        return vy < flickVy * 0.6
    }
}

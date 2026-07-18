import CoreGraphics
import Foundation

/// The touch state machine from docs/controls.md. Owns no UIKit — the
/// overlay view feeds it raw touch events; it emits engine actions and
/// haptic cues through callbacks. Context (gameplay vs menu) is sampled at
/// decision time via `isGameplay`.
final class GestureEngine {
    struct Config {
        var cellPt: CGFloat = 16
        var slopPt: CGFloat = 8
        var tapMaxMs: Double = 180
        var chordMs: Double = 150
        var longPressMs: Double = 350
        var softEngagePt: CGFloat = 20
        var flickWindowMs: Double = 120
        var flickVy: CGFloat = 900
        var flickMinPt: CGFloat = 36
        var swipeUpPt: CGFloat = 30
        var menuStepPt: CGFloat = 40
        var relockRatio: CGFloat = 1.5
        var sensitivity: CGFloat = 1.0
    }

    enum HapticCue {
        case step, rotate, hardDrop, hold, chord
    }

    var config = Config()
    var isGameplay: () -> Bool = { false }
    var viewWidth: CGFloat = 390

    var onPulse: (ApotrisAction) -> Void = { _ in }
    var onHold: (ApotrisAction, Bool) -> Void = { _, _ in }
    var onHaptic: (HapticCue) -> Void = { _ in }

    // MARK: - Per-gesture state

    private enum Phase {
        case idle
        case pending          // touched down, unclassified
        case horizontal
        case verticalDown
        case softHold
        case menuScrub(axisIsX: Bool)
        case consumed         // terminal (hard drop, hold, zone, chord…)
    }

    private struct TouchID: Hashable {
        let value: AnyHashable
    }

    private var phase: Phase = .idle
    private var primary: TouchID?
    private var startPoint: CGPoint = .zero
    private var startTime: TimeInterval = 0
    private var lastPoint: CGPoint = .zero
    private var moveAccum: CGFloat = 0
    private var menuAccum: CGFloat = 0
    private var gameplayGesture = false
    private var primaryHand = 0
    private var flick = FlickClassifier()
    private var longPressTimer: DispatchWorkItem?

    private var chordCandidate: TouchID?
    private var chordStartTime: TimeInterval = 0
    private var chordMoved = false

    // MARK: - Entry points (call from the overlay view)

    func touchBegan(_ id: AnyHashable, at p: CGPoint, time: TimeInterval,
                    hand: Int = 0) {
        let tid = TouchID(value: id)
        if primary == nil {
            primary = tid
            primaryHand = hand
            phase = .pending
            startPoint = p
            lastPoint = p
            startTime = time
            moveAccum = 0
            menuAccum = 0
            gameplayGesture = isGameplay()
            scheduleLongPress()
        } else if chordCandidate == nil,
                  case .pending = phase,
                  (time - startTime) * 1000 < config.chordMs {
            // Second finger fast after the first: two-finger chord candidate.
            chordCandidate = tid
            chordStartTime = time
            chordMoved = false
            cancelLongPress()
        }
        // Additional touches beyond two are ignored.
    }

    func touchMoved(_ id: AnyHashable, at p: CGPoint, time: TimeInterval) {
        let tid = TouchID(value: id)
        if tid == chordCandidate {
            if hypot(p.x - startPoint.x, p.y - startPoint.y) > config.slopPt {
                chordMoved = true
            }
            return
        }
        guard tid == primary else { return }

        let dxTotal = p.x - startPoint.x
        let dyTotal = p.y - startPoint.y
        let stepDx = p.x - lastPoint.x
        let stepDy = p.y - lastPoint.y
        lastPoint = p

        switch phase {
        case .pending:
            let dist = hypot(dxTotal, dyTotal)
            guard dist > config.slopPt else { return }
            cancelLongPress()
            chordCandidate = nil

            if gameplayGesture {
                if abs(dxTotal) >= abs(dyTotal) {
                    phase = .horizontal
                    moveAccum = 0
                    // Re-play the travel so the first cell registers now.
                    accumulateHorizontal(dxTotal)
                } else if dyTotal < 0 {
                    // Upward: hold piece once past threshold.
                    if -dyTotal > config.swipeUpPt {
                        commitHoldPiece()
                    } else {
                        phase = .verticalDown // provisional; may flip to hold
                        beginFlick(time: time, y: p.y)
                    }
                } else {
                    phase = .verticalDown
                    beginFlick(time: time, y: p.y)
                }
            } else {
                phase = .menuScrub(axisIsX: abs(dxTotal) > abs(dyTotal))
                menuAccum = 0
                accumulateMenu(axisIsX: abs(dxTotal) > abs(dyTotal),
                               delta: abs(dxTotal) > abs(dyTotal) ? dxTotal : dyTotal)
            }

        case .horizontal:
            // Re-lock to vertical is deliberately not allowed mid-drag;
            // horizontal drags never soft-drop (controls.md).
            accumulateHorizontal(stepDx)

        case .verticalDown:
            if dyTotal < -config.swipeUpPt {
                commitHoldPiece()
                return
            }
            let verdict = flick.addSample(time: time, y: p.y)
            switch verdict {
            case .hardDrop:
                phase = .consumed
                onPulse(ApotrisActionHardDrop) // ApotrisActionHardDrop
                onHaptic(.hardDrop)
            case .softDrop:
                phase = .softHold
                onHold(ApotrisActionSoftDrop, true) // ApotrisActionSoftDrop
            case .undecided:
                break
            }

        case .softHold:
            // Early wobble forgiveness: strong horizontal motion re-locks…
            // no — once soft drop is held the lock is final (controls.md).
            _ = stepDy

        case .menuScrub(let axisIsX):
            accumulateMenu(axisIsX: axisIsX, delta: axisIsX ? stepDx : stepDy)

        case .idle, .consumed:
            break
        }
    }

    func touchEnded(_ id: AnyHashable, at p: CGPoint, time: TimeInterval) {
        let tid = TouchID(value: id)

        if tid == chordCandidate {
            chordCandidate = nil
            // Both fingers up quickly with no movement → chord action.
            if case .pending = phase,
               !chordMoved,
               (time - chordStartTime) * 1000 < config.tapMaxMs {
                phase = .consumed
                cancelLongPress()
                if gameplayGesture {
                    onPulse(ApotrisActionRotate180) // Rotate180
                } else {
                    onPulse(ApotrisActionCancel) // Cancel
                }
                onHaptic(.chord)
            }
            return
        }

        guard tid == primary else { return }
        cancelLongPress()

        switch phase {
        case .pending:
            let dist = hypot(p.x - startPoint.x, p.y - startPoint.y)
            let ms = (time - startTime) * 1000
            if dist < config.slopPt && ms < config.tapMaxMs {
                if gameplayGesture {
                    if primaryHand == 1 {
                        onPulse(ApotrisActionRotateCW)
                    } else if primaryHand == -1 {
                        onPulse(ApotrisActionRotateCCW)
                    } else if p.x < viewWidth / 2 {
                        onPulse(ApotrisActionRotateCCW)
                    } else {
                        onPulse(ApotrisActionRotateCW)
                    }
                    onHaptic(.rotate)
                } else if primaryHand == -1 {
                    onPulse(ApotrisActionCancel)
                } else {
                    onPulse(ApotrisActionConfirm)
                }
            }
        case .softHold:
            onHold(ApotrisActionSoftDrop, false)
        case .verticalDown:
            // Short vertical nudge that never engaged: treat as tap-ish? No —
            // do nothing (kept deliberate; taps are for rotation).
            break
        default:
            break
        }

        resetPrimary()
    }

    func touchCancelled(_ id: AnyHashable) {
        let tid = TouchID(value: id)
        if tid == chordCandidate {
            chordCandidate = nil
            return
        }
        guard tid == primary else { return }
        cancelLongPress()
        if case .softHold = phase {
            onHold(ApotrisActionSoftDrop, false)
        }
        resetPrimary()
    }

    func reset() {
        cancelLongPress()
        if case .softHold = phase {
            onHold(ApotrisActionSoftDrop, false)
        }
        resetPrimary()
        chordCandidate = nil
    }

    // MARK: - Internals

    private func resetPrimary() {
        primary = nil
        phase = .idle
    }

    private func cellSize() -> CGFloat {
        max(10, config.cellPt / max(0.3, config.sensitivity))
    }

    private func accumulateHorizontal(_ dx: CGFloat) {
        moveAccum += dx
        let cell = cellSize()
        while moveAccum >= cell {
            moveAccum -= cell
            onPulse(ApotrisActionMoveRight) // MoveRight
            onHaptic(.step)
        }
        while moveAccum <= -cell {
            moveAccum += cell
            onPulse(ApotrisActionMoveLeft) // MoveLeft
            onHaptic(.step)
        }
    }

    private func accumulateMenu(axisIsX: Bool, delta: CGFloat) {
        menuAccum += delta
        let step = config.menuStepPt
        while menuAccum >= step {
            menuAccum -= step
            onPulse(.init(axisIsX ? 12 : 10)) // MenuRight : MenuDown
            onHaptic(.step)
        }
        while menuAccum <= -step {
            menuAccum += step
            onPulse(.init(axisIsX ? 11 : 9)) // MenuLeft : MenuUp
            onHaptic(.step)
        }
    }

    private func beginFlick(time: TimeInterval, y: CGFloat) {
        flick = FlickClassifier()
        flick.windowMs = config.flickWindowMs
        flick.flickVy = config.flickVy
        flick.flickMinPt = config.flickMinPt
        flick.softEngagePt = config.softEngagePt
        flick.begin(time: startTime, y: startPoint.y)
        _ = flick.addSample(time: time, y: y)
    }

    private func commitHoldPiece() {
        phase = .consumed
        onPulse(ApotrisActionHold) // Hold
        onHaptic(.hold)
    }

    private func scheduleLongPress() {
        cancelLongPress()
        let work = DispatchWorkItem { [weak self] in
            guard let self, case .pending = self.phase else { return }
            self.phase = .consumed
            if self.gameplayGesture {
                self.onPulse(ApotrisActionZone) // Zone
            } else {
                self.onPulse(ApotrisActionCancel) // Cancel
            }
            self.onHaptic(.hold)
        }
        longPressTimer = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + config.longPressMs / 1000.0, execute: work)
    }

    private func cancelLongPress() {
        longPressTimer?.cancel()
        longPressTimer = nil
    }
}


import XCTest

/// The controls.md classifier contract, pinned by synthetic traces.
/// Asymmetric-cost rule: an accidental hard drop ruins a game, so anything
/// ambiguous must resolve to soft (or stay undecided).
final class FlickClassifierTests: XCTestCase {

    private func run(_ samples: [(t: Double, y: CGFloat)])
        -> FlickClassifier.Verdict
    {
        var f = FlickClassifier()
        f.begin(time: samples[0].t, y: samples[0].y)
        var verdict = FlickClassifier.Verdict.undecided
        for s in samples.dropFirst() {
            verdict = f.addSample(time: s.t, y: s.y)
            if verdict == .hardDrop { break }
        }
        return verdict
    }

    private func trace(vy: CGFloat, durationMs: Double,
                       stepMs: Double = 8) -> [(t: Double, y: CGFloat)]
    {
        var out: [(Double, CGFloat)] = [(0, 0)]
        var t = 0.0
        while t < durationMs {
            t += stepMs
            out.append((t / 1000, CGFloat(t / 1000) * vy))
        }
        return out.map { (t: $0.0, y: $0.1) }
    }

    func testFastFlickIsHardDrop() {
        XCTAssertEqual(run(trace(vy: 1600, durationMs: 60)), .hardDrop)
    }

    func testSlowDragIsSoftDrop() {
        XCTAssertEqual(run(trace(vy: 300, durationMs: 200)), .softDrop)
    }

    func testMediumSlowDragCommitsSoftEarly() {
        // 400 pt/s is clearly controlled — must engage soft inside the window
        // rather than making the player wait 120 ms.
        let verdict = run(trace(vy: 400, durationMs: 100))
        XCTAssertEqual(verdict, .softDrop)
    }

    func testLateSpikeNeverUpgradesToHard() {
        // Slow for 150 ms (soft engages), then a violent spike: must stay soft.
        var samples = trace(vy: 300, durationMs: 150)
        let lastT = samples.last!.t
        let lastY = samples.last!.y
        for i in 1...5 {
            samples.append((t: lastT + Double(i) * 0.008,
                            y: lastY + CGFloat(i) * 20)) // 2500 pt/s
        }
        XCTAssertEqual(run(samples), .softDrop)
    }

    func testShortFastNudgeBelowDistanceFloorStaysUndecided() {
        // Fast but travels only ~20 pt (< FLICK_MIN_PT): not a hard drop.
        let verdict = run(trace(vy: 1600, durationMs: 12))
        XCTAssertNotEqual(verdict, .hardDrop)
    }

    func testJitterStaysUndecided() {
        var samples: [(t: Double, y: CGFloat)] = [(0, 0)]
        for i in 1...20 {
            samples.append((t: Double(i) * 0.008,
                            y: CGFloat(i % 2 == 0 ? 3 : -3)))
        }
        XCTAssertEqual(run(samples), .undecided)
    }

    func testAccelerationInsideWindowIsHardDrop() {
        // Hesitant start, then a real flick, all inside 120 ms.
        var samples: [(t: Double, y: CGFloat)] = [(0, 0)]
        var y: CGFloat = 0
        var t = 0.0
        for _ in 0..<5 { // 40 ms at 250 pt/s
            t += 0.008
            y += 2
            samples.append((t, y))
        }
        for _ in 0..<8 { // then 64 ms at 1875 pt/s
            t += 0.008
            y += 15
            samples.append((t, y))
        }
        XCTAssertEqual(run(samples.map { (t: $0.0, y: $0.1) }), .hardDrop)
    }
}

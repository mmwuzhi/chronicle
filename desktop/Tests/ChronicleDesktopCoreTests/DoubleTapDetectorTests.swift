import XCTest

import ChronicleDesktopCore

final class DoubleTapDetectorTests: XCTestCase {
    func testTwoTapsWithinWindowFire() {
        var d = DoubleTapDetector(window: 0.3)
        XCTAssertFalse(d.register(at: 1.00))  // first tap — arms
        XCTAssertTrue(d.register(at: 1.20))   // second within window — fires
    }

    func testSecondTapOutsideWindowRearms() {
        var d = DoubleTapDetector(window: 0.3)
        XCTAssertFalse(d.register(at: 1.00))
        XCTAssertFalse(d.register(at: 1.50))  // too late — becomes a new first tap
        XCTAssertTrue(d.register(at: 1.70))   // this one completes the pair
    }

    func testThirdTapDoesNotDoubleFire() {
        var d = DoubleTapDetector(window: 0.3)
        XCTAssertFalse(d.register(at: 1.00))
        XCTAssertTrue(d.register(at: 1.20))   // fires and consumes the pair
        XCTAssertFalse(d.register(at: 1.30))  // third tap re-arms, does not fire
    }

    func testResetBreaksPair() {
        var d = DoubleTapDetector(window: 0.3)
        XCTAssertFalse(d.register(at: 1.00))
        d.reset()                              // interrupted by a keypress / chord
        XCTAssertFalse(d.register(at: 1.20))   // within window but invalidated — no fire
    }
}

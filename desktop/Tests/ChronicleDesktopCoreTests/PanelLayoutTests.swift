import CoreGraphics
import XCTest

import ChronicleDesktopCore

final class PanelLayoutTests: XCTestCase {
    private let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)

    func testTopEdgeStaysFixedRegardlessOfHeight() {
        let topShort = PanelLayout.originY(visibleFrame: visible, height: 90) + 90
        let topTall = PanelLayout.originY(visibleFrame: visible, height: 360) + 360
        XCTAssertEqual(topShort, topTall, "panel top edge must not move when height changes")
        XCTAssertEqual(topShort, PanelLayout.topY(visibleFrame: visible))
    }

    func testTopAnchoredAboveCenter() {
        XCTAssertEqual(
            PanelLayout.topY(visibleFrame: visible),
            visible.midY + PanelLayout.topOffsetAboveCenter,
        )
    }

    // Regression for the "re-show jumps upward" bug: open short → grow tall → hide →
    // reopen. Each show computes the origin from the *current* (possibly stale)
    // height, but the resulting top edge must be identical every time.
    func testReshowAtDifferentHeightsLandsOnSameTop() {
        let heights: [CGFloat] = [72, 120, 300, 320, 96]
        let tops = heights.map { PanelLayout.originY(visibleFrame: visible, height: $0) + $0 }
        XCTAssertTrue(tops.allSatisfy { $0 == tops[0] }, "every re-show must land on the same top edge")
    }

    // Two displays side by side: screen B sits to the right of the primary (A).
    private let screenA = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let screenB = CGRect(x: 1440, y: 0, width: 1920, height: 1080)

    // Regression for the "always jumps back to screen A" bug: the cursor's screen,
    // not the window's last screen, must decide where a window opens.
    func testScreenIndexPicksDisplayUnderCursor() {
        let frames = [screenA, screenB]
        XCTAssertEqual(PanelLayout.screenIndex(containing: CGPoint(x: 200, y: 200), screenFrames: frames), 0)
        XCTAssertEqual(PanelLayout.screenIndex(containing: CGPoint(x: 2000, y: 500), screenFrames: frames), 1)
    }

    func testScreenIndexNilWhenCursorOnNoScreen() {
        XCTAssertNil(PanelLayout.screenIndex(containing: CGPoint(x: -50, y: -50), screenFrames: [screenA, screenB]))
    }

    func testCenteredOriginCentersWithinVisibleFrame() {
        let origin = PanelLayout.centeredOrigin(in: screenB, size: CGSize(width: 680, height: 520))
        XCTAssertEqual(origin.x, screenB.midX - 340)
        XCTAssertEqual(origin.y, screenB.midY - 260)
    }
}

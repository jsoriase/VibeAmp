import XCTest
@testable import VibeAmp

final class WindowingTests: XCTestCase {
    func testSnapToScreenEdge() {
        let moving = CGRect(x: 8, y: 100, width: 380, height: 200)
        let workArea = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let result = WindowSnappingCoordinator.snap(moving: moving, others: [:], workArea: workArea)
        XCTAssertEqual(result.origin.x, 0)
        XCTAssertEqual(result.origin.y, 100)
    }

    func testSnapLeftToRight() {
        let other = CGRect(x: 400, y: 100, width: 380, height: 200)
        // Moving window's right edge 10px away from other's left edge.
        let moving = CGRect(x: 400 - 380 - 10, y: 120, width: 380, height: 200)
        let workArea = CGRect(x: 0, y: 0, width: 2000, height: 1000)
        let result = WindowSnappingCoordinator.snap(
            moving: moving,
            others: ["other": other],
            workArea: workArea
        )
        XCTAssertEqual(result.origin.x, 400 - 380)
        XCTAssertEqual(result.target, "other")
    }

    func testSnapTopToBottom() {
        let other = CGRect(x: 100, y: 400, width: 380, height: 200)
        let moving = CGRect(x: 120, y: 400 - 200 + 8, width: 380, height: 200)
        let workArea = CGRect(x: 0, y: 0, width: 2000, height: 1200)
        let result = WindowSnappingCoordinator.snap(
            moving: moving,
            others: ["other": other],
            workArea: workArea
        )
        // Bottom of moving near top of other? Actually moving.maxY ~= other.minY + 8.
        // Our fixture: moving.maxY = 408, other.minY = 400 -> within threshold, snaps below.
        XCTAssertEqual(result.origin.y, 400 - 200)
    }

    func testNoSnapWhenFar() {
        let moving = CGRect(x: 100, y: 100, width: 380, height: 200)
        let other = CGRect(x: 800, y: 800, width: 380, height: 200)
        let workArea = CGRect(x: 0, y: 0, width: 2000, height: 1200)
        let result = WindowSnappingCoordinator.snap(moving: moving, others: ["other": other], workArea: workArea)
        XCTAssertEqual(result.origin.x, 100)
        XCTAssertEqual(result.origin.y, 100)
        XCTAssertNil(result.target)
    }

    func testDescendantsTransitive() {
        let attachments = ["b": "a", "c": "b", "d": "a"]
        let desc = WindowSnappingCoordinator.descendants(of: "a", in: attachments)
        XCTAssertEqual(Set(desc), Set(["b", "c", "d"]))
    }

    func testSanitizedRemovesCycles() {
        let raw = ["a": "b", "b": "a", "c": "zzz"]
        let clean = WindowSnappingCoordinator.sanitized(raw, validRoles: Set(["a", "b", "c"]))
        // Cycle broken, invalid role dropped.
        XCTAssertNil(clean["c"])
        XCTAssertTrue(clean.count <= 1)
    }

    func testRectOnScreenValidation() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        XCTAssertTrue(StateStore.rectIntersectsAnyScreen(CGRect(x: 100, y: 100, width: 380, height: 200), screens: [screen]))
        XCTAssertFalse(StateStore.rectIntersectsAnyScreen(CGRect(x: 5000, y: 5000, width: 380, height: 200), screens: [screen]))
        // Partially overlapping still counts (reposition, don't discard).
        XCTAssertTrue(StateStore.rectIntersectsAnyScreen(CGRect(x: -100, y: 100, width: 380, height: 200), screens: [screen]))
    }

    func testClampedOrigin() {
        let workArea = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let clamped = StateStore.clampedOrigin(
            for: CGSize(width: 380, height: 200),
            desired: CGPoint(x: 2000, y: 2000),
            in: workArea
        )
        XCTAssertEqual(clamped.x, 1440 - 380)
        XCTAssertEqual(clamped.y, 900 - 200)
    }
}

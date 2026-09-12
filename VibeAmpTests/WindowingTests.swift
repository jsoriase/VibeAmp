import XCTest
import AppKit
@testable import VibeAmp

final class WindowingTests: XCTestCase {






    // MARK: - Regressions in the snapping rewrite





    // MARK: - Layout geometry

    /// The default cluster is derived from `defaultSize`, so the columns must
    /// tile with no seams. Hard-coded offsets used to drift out of sync.
    func testDefaultClusterStacksFlush() {
        let frames = WindowLayout.defaultFrames(originTopLeft: CGPoint(x: 0, y: 0))
        guard let player = frames[.player], let eq = frames[.equalizer], let playlist = frames[.playlist] else {
            return XCTFail("missing default frames")
        }
        XCTAssertEqual(player.minY, eq.maxY, "equalizer must sit flush under the player")
        XCTAssertEqual(eq.minY, playlist.maxY, "playlist must sit flush under the equalizer")
        XCTAssertEqual(player.minX, eq.minX)

        guard let search = frames[.search], let art = frames[.art], let log = frames[.log] else {
            return XCTFail("missing default frames")
        }
        XCTAssertEqual(player.maxX, search.minX, "second column must sit flush beside the first")
        XCTAssertEqual(search.minY, art.maxY)
        XCTAssertEqual(search.maxX, log.minX, "third column must sit flush beside the second")
    }

    /// Shade collapses to exactly the header height; the two constants drifted
    /// apart (24 vs 22) and left a sliver of content showing.
    func testShadeHeightMatchesTitleBar() {
        XCTAssertEqual(WindowLayout.shadeHeight, WindowLayout.titleBarHeight)
    }




    // MARK: - Winamp snapping (ported from Webamp's snapUtils)

    private func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat = 380, _ h: CGFloat = 200) -> CGRect {
        CGRect(x: x, y: y, width: w, height: h)
    }

    /// Right edge to left edge: the classic side-by-side dock.
    func testSnapsRightEdgeToLeftEdge() {
        let a = rect(400 - 380 - 8, 120)
        let b = rect(400, 100)
        let snapped = WindowSnappingCoordinator.snap(a, to: b)
        XCTAssertEqual(snapped.x, 400 - 380)
    }

    /// Stacking: a window just under another lands flush against its bottom.
    func testSnapsTopEdgeToBottomEdge() {
        let b = rect(100, 400)
        let a = rect(120, 400 - 200 - 6)   // a's top 6pt below b's bottom
        let snapped = WindowSnappingCoordinator.snap(a, to: b)
        XCTAssertEqual(snapped.y, 400 - 200)
    }

    /// Winamp's overlap test is lenient by the snap distance, so windows that
    /// only meet at a corner still dock. A strict overlap test refused these.
    func testSnapsToADiagonalNeighbour() {
        let b = rect(400, 400)
        let a = rect(400 - 380 - 5, 400 - 200 - 5)
        let snapped = WindowSnappingCoordinator.snap(a, to: b)
        XCTAssertNotNil(snapped.x, "corner neighbours must still snap on x")
        XCTAssertNotNil(snapped.y, "corner neighbours must still snap on y")
    }

    func testDoesNotSnapWhenFarApart() {
        let snapped = WindowSnappingCoordinator.snap(rect(100, 100), to: rect(900, 900))
        XCTAssertNil(snapped.x)
        XCTAssertNil(snapped.y)
        XCTAssertFalse(WindowSnappingCoordinator.abuts(rect(100, 100), rect(900, 900)))
    }

    /// The threshold is exclusive, matching Winamp's `near`.
    func testThresholdIsExclusive() {
        let t = WindowLayout.snapThreshold
        XCTAssertTrue(WindowSnappingCoordinator.near(0, t - 0.5))
        XCTAssertFalse(WindowSnappingCoordinator.near(0, t))
    }

    /// A group snaps when *any* member reaches a stationary window, and the
    /// smallest pull wins so the result never depends on iteration order.
    func testGroupSnapUsesSmallestPullAndIsDeterministic() {
        let moving = [rect(100, 600), rect(100, 400)]
        let stationary = [rect(100, 400 - 200 - 9), rect(486, 600)]   // 9pt below, 6pt to the right
        let diffs = (0..<40).map { _ in
            WindowSnappingCoordinator.snapDiffManyToMany(moving, stationary)
        }
        XCTAssertEqual(Set(diffs.map(\.dy)).count, 1, "must not depend on dictionary order")
        XCTAssertEqual(Set(diffs.map(\.dx)).count, 1)
        XCTAssertEqual(diffs[0].dx, 6, "the 6pt pull beats the 9pt one")
    }

    func testScreenEdgesAttractNearbyWindowsButAllowCrossing() {
        let screen = rect(0, 0, 1440, 900)
        let nearRight = WindowSnappingCoordinator.snapToScreenEdgesDiff(rect(1054, 300), workArea: screen)
        XCTAssertEqual(nearRight.dx, 6)
        for frame in [rect(1200, 300), rect(-100, 300), rect(300, 800), rect(300, -100)] {
            let diff = WindowSnappingCoordinator.snapToScreenEdgesDiff(frame, workArea: screen)
            XCTAssertEqual(diff.dx, 0)
            XCTAssertEqual(diff.dy, 0)
        }
    }

    func testCrossDisplayGroupDoesNotJumpIntoDestinationScreen() {
        let group = rect(1200, 100, 1140, 644)
        let rightScreen = rect(1440, 0, 1920, 1080)
        let diff = WindowSnappingCoordinator.snapToScreenEdgesDiff(group, workArea: rightScreen)
        XCTAssertEqual(diff.dx, 0)
        XCTAssertEqual(diff.dy, 0)
        let upperScreen = rect(-400, 900, 1920, 1080)
        let verticalDiff = WindowSnappingCoordinator.snapToScreenEdgesDiff(rect(100, 700, 760, 644), workArea: upperScreen)
        XCTAssertEqual(verticalDiff.dx, 0)
        XCTAssertEqual(verticalDiff.dy, 0)
        let leftScreen = rect(-1920, -200, 1920, 1080)
        XCTAssertEqual(WindowSnappingCoordinator.snapToScreenEdgesDiff(rect(-1914, 100), workArea: leftScreen).dx, -6)
    }

    func testPlaylistsPlacementStaysBesidePlayerOnItsDisplay() {
        let screen = rect(-1920, 0, 1920, 1080)
        let player = rect(-500, 600, 380, 212)
        let size = WindowRole.savedPlaylists.defaultSize
        let origin = WindowLayout.adjacentOrigin(for: size, beside: player, in: screen)
        let playlist = CGRect(origin: origin, size: size)
        XCTAssertTrue(screen.contains(playlist))
        XCTAssertEqual(playlist.maxX, player.minX, "Use the left side when the right side is full")
        XCTAssertEqual(playlist.maxY, player.maxY)

        let lowPlayer = rect(-400, 30, 380, 212)
        let clamped = WindowLayout.adjacentOrigin(for: size, beside: lowPlayer, in: screen)
        XCTAssertTrue(screen.contains(CGRect(origin: clamped, size: size)))
    }

    // MARK: - Grouping

    /// Winamp derives the travelling group from geometry, not a stored graph:
    /// everything transitively touching the window you grabbed.
    func testConnectedGroupFollowsTheStack() {
        let frames: [String: CGRect] = [
            "player": rect(0, 400, 380, 200),
            "equalizer": rect(0, 200, 380, 200),   // flush under player
            "playlist": rect(0, 0, 380, 200),      // flush under equalizer
            "log": rect(900, 0, 380, 200),         // far away
        ]
        let group = WindowSnappingCoordinator.connectedGroup(startingAt: "player", among: frames)
        XCTAssertEqual(group, ["player", "equalizer", "playlist"])
        XCTAssertFalse(group.contains("log"))
    }

    func testConnectedGroupIsJustTheWindowWhenNothingTouches() {
        let frames: [String: CGRect] = ["player": rect(0, 400), "log": rect(900, 0)]
        XCTAssertEqual(WindowSnappingCoordinator.connectedGroup(startingAt: "player", among: frames), ["player"])
    }

    // MARK: - Keeping docks across a size change (shade)

    /// Shading a window walks the whole column beneath it up by the height lost,
    /// transitively — the playlist under the equalizer under the player.
    func testShadingWalksTheColumnUp() {
        let frames: [String: CGRect] = [
            "player": rect(0, 400, 380, 200),
            "equalizer": rect(0, 200, 380, 200),
            "playlist": rect(0, 0, 380, 200),
        ]
        let graph = WindowSnappingCoordinator.edgeGraph(frames)
        XCTAssertEqual(graph.below["player"], "equalizer")
        XCTAssertEqual(graph.below["equalizer"], "playlist")

        // Player collapses 200 -> 24.
        let diffs = WindowSnappingCoordinator.positionDiff(
            graph: graph,
            sizeDiff: ["player": CGSize(width: 0, height: 24 - 200)]
        )
        XCTAssertEqual(diffs["equalizer"]?.dy, 176, "equalizer rides up by the height lost")
        XCTAssertEqual(diffs["playlist"]?.dy, 176, "and the playlist follows it")
        XCTAssertEqual(diffs["player"]?.dy, 0, "the shaded window keeps its own top edge")
    }

    /// Unshading pushes the column back down by the same amount.
    func testUnshadingWalksTheColumnBackDown() {
        let frames: [String: CGRect] = [
            "player": rect(0, 576, 380, 24),
            "equalizer": rect(0, 376, 380, 200),
        ]
        let graph = WindowSnappingCoordinator.edgeGraph(frames)
        let diffs = WindowSnappingCoordinator.positionDiff(
            graph: graph,
            sizeDiff: ["player": CGSize(width: 0, height: 200 - 24)]
        )
        XCTAssertEqual(diffs["equalizer"]?.dy, -176)
    }

    /// Windows that merely sit near each other are not docked: the edge graph
    /// demands a real shared edge, unlike the lenient snapping test.
    func testEdgeGraphNeedsAnExactSharedEdge() {
        let frames: [String: CGRect] = [
            "player": rect(0, 405, 380, 200),      // 5pt gap
            "equalizer": rect(0, 200, 380, 200),
        ]
        XCTAssertNil(WindowSnappingCoordinator.edgeGraph(frames).below["player"])
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

@MainActor
final class SavedPlaylistsWindowTests: XCTestCase {
    func testPlaylistsSnapTravelWithPlayerAndPersistVisibility() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = StateStore(fileURL: directory.appendingPathComponent("state.json"))
        let manager = WindowManager()
        manager.configure(stateStore: store, log: nil)
        manager.createAll(hosts: [.player: NSView(), .savedPlaylists: NSView()])
        defer {
            manager.window(for: .player)?.orderOut(nil)
            manager.close(.savedPlaylists)
            store.flush()
            try? FileManager.default.removeItem(at: directory)
        }
        let player = try XCTUnwrap(manager.window(for: .player))
        let playlists = try XCTUnwrap(manager.window(for: .savedPlaylists))
        XCTAssertFalse(manager.isVisible(.savedPlaylists))
        manager.toggle(.savedPlaylists)
        XCTAssertTrue(playlists.isVisible)
        XCTAssertTrue(manager.isVisible(.savedPlaylists))

        let screen = try XCTUnwrap(player.screen).visibleFrame
        let origin = CGPoint(x: screen.minX + 50, y: screen.minY + 80)
        player.setFrameOrigin(origin)
        playlists.setFrameOrigin(CGPoint(x: player.frame.maxX + 100, y: origin.y))
        let mouse = CGPoint(x: playlists.frame.midX, y: playlists.frame.maxY - 12)
        manager.dragBegin(.savedPlaylists, mouse: mouse)
        manager.dragUpdate(.savedPlaylists, mouse: CGPoint(x: mouse.x - 92, y: mouse.y))
        manager.dragEnd(.savedPlaylists)
        XCTAssertEqual(playlists.frame.minX, player.frame.maxX)
        XCTAssertEqual(player.frame.origin, origin, "Dragging playlists must leave the player in place")

        let dockedOrigin = playlists.frame.origin
        let playerMouse = CGPoint(x: player.frame.midX, y: player.frame.maxY - 12)
        manager.dragBegin(.player, mouse: playerMouse)
        manager.dragUpdate(.player, mouse: CGPoint(x: playerMouse.x + 40, y: playerMouse.y + 30))
        manager.dragEnd(.player)
        XCTAssertEqual(playlists.frame.origin, CGPoint(x: dockedOrigin.x + 40, y: dockedOrigin.y + 30))
        XCTAssertEqual(playlists.frame.minX, player.frame.maxX)

        manager.toggleShade(.savedPlaylists)
        XCTAssertEqual(playlists.frame.height, WindowLayout.shadeHeight)
        manager.toggleShade(.savedPlaylists)
        XCTAssertEqual(playlists.frame.height, WindowRole.savedPlaylists.defaultSize.height)
        manager.toggle(.savedPlaylists)
        XCTAssertFalse(playlists.isVisible)
        let visible = store.get([String: Bool].self, key: "windowVisible", fallback: [:])
        XCTAssertEqual(visible[WindowRole.savedPlaylists.rawValue], false)
        let positions = store.get([String: WindowState.WindowPoint].self, key: "windowPositions", fallback: [:])
        XCTAssertEqual(positions[WindowRole.savedPlaylists.rawValue]?.x, Double(playlists.frame.minX))
    }
}

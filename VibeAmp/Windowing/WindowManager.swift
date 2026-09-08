import AppKit
import SwiftUI
import Observation

/// Owns the six independent retro modules. All windows observe the same
/// native Swift state — no IPC. Handles creation, visibility, shade,
/// snapping/docking, and layout persistence.
@MainActor
@Observable
final class WindowManager: NSObject {
    var visible: [WindowRole: Bool] = [:]
    var shaded: [WindowRole: Bool] = [:]
    /// Focused module, so the chrome can dim inactive title bars.
    var keyRole: WindowRole?

    private var windows: [WindowRole: RetroWindow] = [:]
    private var lastFrames: [WindowRole: NSRect] = [:]
    private var expandedSizes: [WindowRole: NSSize] = [:]
    private var stateStore: StateStore?
    private var log: AppLog?

    /// Origins we set ourselves. A matching windowDidMove is our own echo, not
    /// the user dragging.
    private var expectedOrigins: [WindowRole: CGPoint] = [:]

    /// Everything a drag needs, captured once when it starts.
    ///
    /// Winamp computes the offset from where the mouse went down, not from the
    /// previous frame. Accumulating per-frame deltas — what this used to do —
    /// drifts, and fights AppKit, which is recomputing the dragged window's
    /// position from the same mouse-down anchor on every event.
    private struct DragSession {
        let role: WindowRole
        /// Screen position of the pointer when the drag began. Winamp measures
        /// the offset from here, never from the previous frame.
        let mouseStart: CGPoint
        /// Where each travelling window sat when the drag began.
        let startOrigins: [WindowRole: CGPoint]
        let sizes: [WindowRole: CGSize]
        /// Frames of the windows staying put, to snap against.
        let stationary: [CGRect]
        /// The dragged window's own origin at drag start.
        let anchor: CGPoint
        let workArea: CGRect
    }
    private var drag: DragSession?

    var onPlayerClose: (() -> Void)?

    // MARK: - Setup

    func configure(stateStore: StateStore?, log: AppLog?) {
        self.stateStore = stateStore
        self.log = log
    }

    func window(for role: WindowRole) -> RetroWindow? {
        windows[role]
    }

    func isVisible(_ role: WindowRole) -> Bool {
        visible[role] ?? (role == .player)
    }

    func isShaded(_ role: WindowRole) -> Bool {
        shaded[role] ?? false
    }

    func isKey(_ role: WindowRole) -> Bool {
        keyRole == role
    }

    /// Creates all six windows. `hosts` maps each role to its SwiftUI content.
    func createAll(hosts: [WindowRole: NSView]) {
        guard windows.isEmpty else { return }

        let primary = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let fallback = defaultFrames(in: primary)

        // Restored positions (AppKit bottom-left origins, validated on-screen).
        // Migrates Electron "bounds"/"visible" on first native launch.
        var restoredPositions: [String: WindowState.WindowPoint] = [:]
        var restoredVisible: [String: Bool] = [:]
        var restoredShaded: [String: Bool] = [:]
        if let store = stateStore {
            restoredPositions = store.get([String: WindowState.WindowPoint].self, key: "windowPositions", fallback: [:])
            restoredVisible = store.get([String: Bool].self, key: "windowVisible", fallback: [:])
            restoredShaded = store.get([String: Bool].self, key: "windowShaded", fallback: [:])
            if restoredPositions.isEmpty {
                let electronBounds = store.get([String: WindowState.WindowPoint].self, key: "bounds", fallback: [:])
                if !electronBounds.isEmpty { restoredPositions = electronBounds }
            }
            if restoredVisible.isEmpty {
                let electronVisible = store.get([String: Bool].self, key: "visible", fallback: [:])
                if !electronVisible.isEmpty { restoredVisible = electronVisible }
            }
        }

        for role in WindowRole.allCases {
            guard let host = hosts[role] else { continue }
            let size = role.defaultSize
            var frame = fallback[role] ?? NSRect(x: primary.minX + 20, y: primary.minY + 20, width: size.width, height: size.height)
            if let saved = restoredPositions[role.rawValue] {
                let candidate = NSRect(x: saved.x, y: saved.y, width: size.width, height: size.height)
                if Self.frameIntersectsAnyScreen(candidate) {
                    frame = candidate
                }
            }
            let win = RetroWindow(role: role, contentView: host, frame: frame)
            win.delegate = self
            windows[role] = win
            lastFrames[role] = frame

            let shouldShow: Bool = {
                if role == .player { return true }
                if let saved = restoredVisible[role.rawValue] { return saved }
                return true
            }()
            visible[role] = shouldShow
            if shouldShow {
                win.orderFrontRegardless()
            }

            if restoredShaded[role.rawValue] == true {
                // Apply shade after showing so geometry is settled.
                DispatchQueue.main.async { [weak self] in self?.setShaded(true, for: role) }
            } else {
                shaded[role] = false
            }
        }
        saveLayout()
    }

    private func defaultFrames(in screenFrame: NSRect) -> [WindowRole: NSRect] {
        // Centre the three-column cluster on the current display.
        let clusterWidth = WindowLayout.clusterWidth
        let originX = screenFrame.minX + max(20, (screenFrame.width - clusterWidth) / 2)
        // AppKit origin is bottom-left: place cluster so its top sits just below the menu bar.
        let topY = screenFrame.maxY - 20
        var frames: [WindowRole: NSRect] = [:]
        for role in WindowRole.allCases {
            let size = role.defaultSize
            let offset = role.defaultOffset
            frames[role] = NSRect(
                x: originX + offset.x,
                y: topY - offset.y - size.height,
                width: size.width,
                height: size.height
            )
        }
        return frames
    }

    // MARK: - Visibility

    func toggle(_ role: WindowRole) {
        guard role != .player else { return }
        guard let win = windows[role] else { return }
        if win.isVisible {
            win.orderOut(nil)
            visible[role] = false
        } else {
            ensureOnScreen(role)
            win.makeKeyAndOrderFront(nil)
            visible[role] = true
        }
        saveLayout()
    }

    func show(_ role: WindowRole) {
        guard let win = windows[role] else { return }
        ensureOnScreen(role)
        win.makeKeyAndOrderFront(nil)
        visible[role] = true
        saveLayout()
    }

    func showAll() {
        for role in WindowRole.allCases {
            ensureOnScreen(role)
            windows[role]?.orderFrontRegardless()
            visible[role] = true
        }
        saveLayout()
    }

    /// Winamp's minimize sends the whole player to the taskbar, and that is
    /// what this does: NSWindow.miniaturize is a no-op on the borderless
    /// windows we need for live snapping, so the app hides instead and comes
    /// back from the Dock. Verified — the miniaturize call did nothing.
    func minimize(_ role: WindowRole) {
        persistNow()
        NSApp.hide(nil)
    }

    func close(_ role: WindowRole) {
        if role == .player {
            onPlayerClose?()
            NSApp.terminate(nil)
            return
        }
        windows[role]?.orderOut(nil)
        visible[role] = false
        saveLayout()
    }

    /// Re-tiles every module into the default cluster on the active screen.
    /// The escape hatch when a layout ends up scattered or off-screen.
    func resetLayout() {
        let screen = NSApp.keyWindow?.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frames = defaultFrames(in: screen)
        for role in WindowRole.allCases {
            guard let win = windows[role], let frame = frames[role] else { continue }
            if shaded[role] == true {
                shaded[role] = false
                expandedSizes[role] = frame.size
            }
            setFrame(frame, for: role, on: win)
        }
        saveLayout()
        log?.info("Layout reset to default cluster")
    }

    func focusSearch() {
        show(.search)
        windows[.search]?.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .vibeAmpFocusSearch, object: nil)
    }

    func focusURLField() {
        focusSearch()
        NotificationCenter.default.post(name: .vibeAmpFocusURL, object: nil)
    }

    // MARK: - Shade (Winamp-style collapse to title bar)

    func toggleShade(_ role: WindowRole) {
        setShaded(!(shaded[role] ?? false), for: role)
    }

    private func setShaded(_ shade: Bool, for role: WindowRole) {
        guard let win = windows[role] else { return }
        guard shade != (shaded[role] ?? false) else { return }
        let frame = win.frame
        let oldTop = frame.maxY
        let oldHeight = frame.height

        // Which windows are docked where, *before* the size changes.
        let graph = WindowSnappingCoordinator.edgeGraph(visibleFrames())

        if shade { expandedSizes[role] = frame.size }
        let targetHeight = shade ? WindowLayout.shadeHeight : (expandedSizes[role] ?? role.defaultSize).height

        setFrame(NSRect(x: frame.minX, y: oldTop - targetHeight, width: frame.width, height: targetHeight), for: role, on: win)
        // AppKit can clamp the height (titled windows have a floor); re-pin the
        // top edge to whatever height we actually got so nothing drifts.
        var settled = win.frame
        settled.origin.y = oldTop - settled.height
        setFrame(settled, for: role, on: win)
        shaded[role] = shade

        // Walk the column: everything resting under the collapsed window rides
        // up by the height it lost, and their own dependents follow.
        let sizeDiff = [role.rawValue: CGSize(width: 0, height: win.frame.height - oldHeight)]
        let diffs = WindowSnappingCoordinator.positionDiff(graph: graph, sizeDiff: sizeDiff)
        var moves: [(WindowRole, NSPoint)] = []
        for (key, delta) in diffs where delta.dy != 0 || delta.dx != 0 {
            guard let other = WindowRole(rawValue: key), other != role, let otherWin = windows[other] else { continue }
            moves.append((other, NSPoint(x: otherWin.frame.minX + delta.dx, y: otherWin.frame.minY + delta.dy)))
        }
        moveTogether(moves)
        saveLayout()
    }

    private func setOrigin(_ origin: NSPoint, for role: WindowRole, on win: RetroWindow) {
        expectedOrigins[role] = origin
        win.setFrameOrigin(origin)
        // Deliberately not reading `win.frame` back: every read is a round trip
        // to the window server, and doing five of them per mouse-move is what
        // made docked windows visibly trail the one under the cursor.
        lastFrames[role] = NSRect(origin: origin, size: lastFrames[role]?.size ?? win.frame.size)
    }

    private func setFrame(_ frame: NSRect, for role: WindowRole, on win: RetroWindow) {
        expectedOrigins[role] = frame.origin
        win.setFrame(frame, display: true)
        lastFrames[role] = win.frame
    }

    /// Moves several windows in one pass.
    ///
    /// No NSDisableScreenUpdates bracket: it is deprecated precisely because it
    /// costs more than it saves, and since 10.11 AppKit already coalesces the
    /// moves made in a single turn of the run loop. The win here is upstream —
    /// nothing in this loop talks to the window server except the move itself.
    private func moveTogether(_ moves: [(WindowRole, NSPoint)]) {
        for (role, origin) in moves {
            guard let win = windows[role] else { continue }
            setOrigin(origin, for: role, on: win)
        }
    }

    private func visibleFrames() -> [String: CGRect] {
        var frames: [String: CGRect] = [:]
        for (role, win) in windows where win.isVisible {
            frames[role.rawValue] = win.frame
        }
        return frames
    }

    // MARK: - Dragging

    /// Pointer went down on a title bar.
    ///
    /// Winamp works out which windows travel together right here, from where
    /// they are sitting: everything transitively touching the one you grabbed.
    /// And only the main window carries a group — pick up the equalizer or the
    /// playlist and it moves alone, however it is docked.
    func dragBegin(_ role: WindowRole, mouse: CGPoint) {
        var frames = visibleFrames()
        guard let own = frames[role.rawValue] else { return }

        let groupKeys: Set<String> = role == .player
            ? WindowSnappingCoordinator.connectedGroup(startingAt: role.rawValue, among: frames)
            : [role.rawValue]
        let group = Set(groupKeys.compactMap(WindowRole.init(rawValue:)))

        var startOrigins: [WindowRole: CGPoint] = [:]
        var sizes: [WindowRole: CGSize] = [:]
        var stationary: [CGRect] = []
        for (key, frame) in frames {
            guard let other = WindowRole(rawValue: key) else { continue }
            if group.contains(other) {
                startOrigins[other] = frame.origin
                sizes[other] = frame.size
            } else {
                stationary.append(frame)
            }
        }
        frames.removeAll()

        drag = DragSession(
            role: role,
            mouseStart: mouse,
            startOrigins: startOrigins,
            sizes: sizes,
            stationary: stationary,
            anchor: own.origin,
            workArea: windows[role]?.screen?.visibleFrame
                ?? NSScreen.main?.visibleFrame
                ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        )
    }

    /// Pointer moved. Everything is derived from the mouse-down anchor, so the
    /// group can never drift away from the cursor over a long drag.
    func dragUpdate(_ role: WindowRole, mouse: CGPoint) {
        guard let session = drag, session.role == role else { return }

        let proposed = CGVector(dx: mouse.x - session.mouseStart.x, dy: mouse.y - session.mouseStart.y)

        let proposedFrames = session.startOrigins.map { member, origin in
            CGRect(origin: CGPoint(x: origin.x + proposed.dx, y: origin.y + proposed.dy),
                   size: session.sizes[member] ?? .zero)
        }

        // The group snaps as a unit — any member reaching a stationary window
        // pulls the whole set into place — and its bounding box stays on screen.
        let snapDiff = WindowSnappingCoordinator.snapDiffManyToMany(proposedFrames, session.stationary)
        let withinDiff = WindowSnappingCoordinator.snapWithinDiff(
            WindowSnappingCoordinator.boundingBox(proposedFrames),
            workArea: session.workArea
        )
        let final = WindowSnappingCoordinator.applyMultipleDiffs(proposed, [snapDiff, withinDiff])

        var moves: [(WindowRole, NSPoint)] = []
        moves.reserveCapacity(session.startOrigins.count)
        for (member, origin) in session.startOrigins {
            let target = NSPoint(x: (origin.x + final.dx).rounded(), y: (origin.y + final.dy).rounded())
            if windows[member]?.frame.origin != target { moves.append((member, target)) }
        }
        moveTogether(moves)
    }

    func dragEnd(_ role: WindowRole) {
        guard drag?.role == role else { return }
        drag = nil
        for (member, win) in windows { lastFrames[member] = win.frame }
        saveLayout()
    }

    // MARK: - Persistence

    func saveLayout() {
        guard let store = stateStore else { return }
        var positions: [String: WindowState.WindowPoint] = [:]
        var vis: [String: Bool] = [:]
        var sh: [String: Bool] = [:]
        for role in WindowRole.allCases {
            if let win = windows[role] {
                let frame = win.frame
                positions[role.rawValue] = WindowState.WindowPoint(x: Double(frame.origin.x), y: Double(frame.origin.y))
            }
            vis[role.rawValue] = visible[role] ?? true
            sh[role.rawValue] = shaded[role] ?? false
        }
        store.set(key: "windowPositions", value: positions)
        store.set(key: "windowVisible", value: vis)
        store.set(key: "windowShaded", value: sh)
        // No "attachments" key any more: which windows are docked is a fact
        // about where they sit, recomputed from geometry whenever it matters.
    }

    func persistNow() {
        saveLayout()
        stateStore?.flush()
    }

    private func ensureOnScreen(_ role: WindowRole) {
        guard let win = windows[role] else { return }
        if !Self.frameIntersectsAnyScreen(win.frame) {
            let screen = win.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
            let size = win.frame.size
            let fallback = defaultFrames(in: screen)[role] ?? win.frame
            let clamped = StateStore.clampedOrigin(
                for: size,
                desired: fallback.origin,
                in: screen
            )
            setOrigin(clamped, for: role, on: win)
        }
    }

    static func frameIntersectsAnyScreen(_ frame: NSRect) -> Bool {
        let screens = NSScreen.screens.map(\.visibleFrame)
        guard !screens.isEmpty else { return true }
        return StateStore.rectIntersectsAnyScreen(frame, screens: screens)
    }
}

// MARK: - NSWindowDelegate

extension WindowManager: NSWindowDelegate {
    func windowDidMove(_ notification: Notification) {
        // Dragging is driven by the chrome's gesture, so this only records
        // moves AppKit makes on its own (Spaces, display changes).
        guard let win = notification.object as? NSWindow,
              let role = (win as? RetroWindow)?.role ?? role(for: win)
        else { return }
        lastFrames[role] = win.frame
        if drag == nil { saveLayout() }
    }

    func windowWillClose(_ notification: Notification) {
        // Windows are never destroyed by close — hide instead (except player quits).
        guard let win = notification.object as? NSWindow,
              let role = (win as? RetroWindow)?.role ?? role(for: win)
        else { return }
        // Prevent the actual close; hide and keep state alive.
        // Note: RetroWindow has isReleasedWhenClosed = false.
        if role == .player {
            persistNow()
        } else {
            visible[role] = false
            saveLayout()
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let win = notification.object as? NSWindow,
              let role = (win as? RetroWindow)?.role ?? role(for: win)
        else { return }
        keyRole = role
    }

    func windowDidResignKey(_ notification: Notification) {
        guard let win = notification.object as? NSWindow,
              let role = (win as? RetroWindow)?.role ?? role(for: win)
        else { return }
        if keyRole == role { keyRole = nil }
    }

    private func role(for window: NSWindow) -> WindowRole? {
        windows.first(where: { $0.value === window })?.key
    }
}

extension Notification.Name {
    static let vibeAmpFocusSearch = Notification.Name("vibeAmpFocusSearch")
    static let vibeAmpFocusURL = Notification.Name("vibeAmpFocusURL")
}

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

    private var windows: [WindowRole: RetroWindow] = [:]
    private var lastFrames: [WindowRole: NSRect] = [:]
    private var programmatic: Set<WindowRole> = []
    private var userDragRole: WindowRole?
    private var attachments: [WindowRole: WindowRole] = [:]
    private var expandedSizes: [WindowRole: NSSize] = [:]
    private var snapWorkItems: [WindowRole: DispatchWorkItem] = [:]
    private var stateStore: StateStore?
    private var log: AppLog?

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

    /// Creates all six windows. `hosts` maps each role to its SwiftUI content.
    func createAll(hosts: [WindowRole: NSView]) {
        guard windows.isEmpty else { return }
        restoreAttachments()

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
        // Center the ~1156×584 cluster reasonably on the current display.
        let clusterWidth: CGFloat = 776 + 380
        let originX = screenFrame.minX + max(20, (screenFrame.width - clusterWidth) / 2)
        // AppKit origin is bottom-left: place cluster so its top sits ~60px below menu bar.
        let topY = screenFrame.maxY - 40
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

    func minimize(_ role: WindowRole) {
        windows[role]?.miniaturize(nil)
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
        let currentlyShaded = shaded[role] ?? false
        guard shade != currentlyShaded else { return }
        var frame = win.frame
        if shade {
            expandedSizes[role] = frame.size
            let targetHeight = WindowLayout.shadeHeight
            let delta = frame.height - targetHeight
            frame.size.height = targetHeight
            // Keep the top edge fixed (AppKit grows down otherwise).
            frame.origin.y += delta
            programmatic.insert(role)
            win.setFrame(frame, display: true)
            lastFrames[role] = frame
            shaded[role] = true
            // Pull windows docked underneath up to meet the new bottom edge.
            let previousBottom = frame.origin.y + targetHeight + delta
            for (child, parent) in attachments where parent == role {
                guard let childWin = windows[child] else { continue }
                if childWin.frame.origin.y + childWin.frame.height < previousBottom - 2
                    && childWin.frame.origin.y < frame.origin.y {
                    // Child sits below: move up by the collapsed delta.
                    moveRoles([child] + descendants(of: child), by: CGVector(dx: 0, dy: delta))
                } else if childWin.frame.origin.y >= previousBottom - 2 {
                    // Child was attached at the bottom edge precisely.
                    moveRoles([child] + descendants(of: child), by: CGVector(dx: 0, dy: delta))
                }
            }
        } else {
            let restored = expandedSizes[role] ?? role.defaultSize
            let delta = restored.height - frame.height
            frame.size.height = restored.height
            frame.origin.y -= delta
            programmatic.insert(role)
            win.setFrame(frame, display: true)
            lastFrames[role] = frame
            shaded[role] = false
            // Push docked-below windows back down.
            for (child, parent) in attachments where parent == role {
                guard windows[child] != nil else { continue }
                moveRoles([child] + descendants(of: child), by: CGVector(dx: 0, dy: -delta))
            }
        }
        saveLayout()
    }

    // MARK: - Attachment graph + movement

    private func descendants(of role: WindowRole) -> [WindowRole] {
        var stringMap: [String: String] = [:]
        for (child, parent) in attachments {
            stringMap[child.rawValue] = parent.rawValue
        }
        let strings = WindowSnappingCoordinator.descendants(of: role.rawValue, in: stringMap)
        return strings.compactMap { WindowRole(rawValue: $0) }
    }

    private func moveRoles(_ roles: [WindowRole], by delta: CGVector) {
        guard delta.dx != 0 || delta.dy != 0 else { return }
        for role in roles {
            guard let win = windows[role] else { continue }
            var frame = win.frame
            frame.origin.x += delta.dx
            frame.origin.y += delta.dy
            programmatic.insert(role)
            win.setFrameOrigin(frame.origin)
            lastFrames[role] = win.frame
        }
    }

    private func restoreAttachments() {
        let valid = Set(WindowRole.allCases.map(\.rawValue))
        let raw: [String: String] = stateStore?.get([String: String].self, key: "attachments", fallback: [:])
            ?? Dictionary(uniqueKeysWithValues: WindowLayout.defaultAttachments.map { ($0.key.rawValue, $0.value.rawValue) })
        let clean = WindowSnappingCoordinator.sanitized(raw, validRoles: valid)
        attachments = [:]
        for (child, parent) in clean {
            if let c = WindowRole(rawValue: child), let p = WindowRole(rawValue: parent) {
                attachments[c] = p
            }
        }
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
        var attach: [String: String] = [:]
        for (child, parent) in attachments {
            attach[child.rawValue] = parent.rawValue
        }
        store.set(key: "windowPositions", value: positions)
        store.set(key: "windowVisible", value: vis)
        store.set(key: "windowShaded", value: sh)
        store.set(key: "attachments", value: attach)
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
            programmatic.insert(role)
            win.setFrameOrigin(clamped)
            lastFrames[role] = win.frame
        }
    }

    static func frameIntersectsAnyScreen(_ frame: NSRect) -> Bool {
        let screens = NSScreen.screens.map(\.visibleFrame)
        guard !screens.isEmpty else { return true }
        return StateStore.rectIntersectsAnyScreen(frame, screens: screens)
    }
}

// MARK: - NSWindowDelegate (snapping + docking)

extension WindowManager: NSWindowDelegate {
    func windowDidMove(_ notification: Notification) {
        guard let win = notification.object as? NSWindow,
              let role = (win as? RetroWindow)?.role ?? role(for: win)
        else { return }
        let frame = win.frame
        let previous = lastFrames[role] ?? frame
        lastFrames[role] = frame

        if programmatic.contains(role) {
            programmatic.remove(role)
            return
        }

        // User drag: detach from parent (mirrors Electron: detach on move,
        // since will-move doesn't fire reliably), move descendants along.
        attachments.removeValue(forKey: role)
        userDragRole = role
        let delta = CGVector(dx: frame.origin.x - previous.origin.x, dy: frame.origin.y - previous.origin.y)
        if delta.dx != 0 || delta.dy != 0 {
            moveRoles(descendants(of: role), by: delta)
        }

        // Debounced snap at settle — avoids jitter mid-drag.
        snapWorkItems[role]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.finishDrag(for: role)
            }
        }
        snapWorkItems[role] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func finishDrag(for role: WindowRole) {
        guard userDragRole == role, let win = windows[role] else { return }
        userDragRole = nil
        let frame = win.frame
        let screenFrame = win.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? frame
        let descendantSet = Set(descendants(of: role).map(\.rawValue) + [role.rawValue])

        var others: [String: CGRect] = [:]
        for (otherRole, otherWin) in windows where otherRole != role {
            if descendantSet.contains(otherRole.rawValue) { continue }
            if !otherWin.isVisible { continue }
            others[otherRole.rawValue] = otherWin.frame
        }

        let result = WindowSnappingCoordinator.snap(
            moving: frame,
            others: others,
            workArea: screenFrame
        )
        let delta = CGVector(dx: result.origin.x - frame.origin.x, dy: result.origin.y - frame.origin.y)
        if delta.dx != 0 || delta.dy != 0 {
            moveRoles([role] + descendants(of: role), by: delta)
        }
        if let target = result.target, let targetRole = WindowRole(rawValue: target) {
            attachments[role] = targetRole
        }
        saveLayout()
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
        // No-op: placeholder for future active-window highlighting.
    }

    private func role(for window: NSWindow) -> WindowRole? {
        windows.first(where: { $0.value === window })?.key
    }
}

extension Notification.Name {
    static let vibeAmpFocusSearch = Notification.Name("vibeAmpFocusSearch")
    static let vibeAmpFocusURL = Notification.Name("vibeAmpFocusURL")
}

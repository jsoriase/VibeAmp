import AppKit
import Observation
import SwiftUI

struct RetroContextMenuAction {
    let title: String
    let symbol: String
    var role: ButtonRole? = nil
    let perform: () -> Void
}

extension View {
    func retroContextMenu(_ actions: [RetroContextMenuAction]) -> some View {
        background(RetroMenuAnchor(actions: actions))
            .accessibilityActions {
                ForEach(actions.indices, id: \.self) { index in
                    Button(actions[index].title, role: actions[index].role, action: actions[index].perform)
                }
            }
    }
}

/// A non-interactive background observes secondary clicks inside its visible
/// row, so the SwiftUI button keeps its normal primary-click behavior.
private struct RetroMenuAnchor: NSViewRepresentable {
    let actions: [RetroContextMenuAction]

    func makeNSView(context: Context) -> AnchorView { AnchorView() }
    func updateNSView(_ view: AnchorView, context: Context) { view.actions = actions }
    static func dismantleNSView(_ view: AnchorView, coordinator: ()) { view.stopObserving() }

    final class AnchorView: NSView {
        var actions: [RetroContextMenuAction] = []
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
                guard let self, event.window === self.window, !self.isHiddenOrHasHiddenAncestor,
                      event.type == .rightMouseDown || event.modifierFlags.contains(.control) else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                // Non-clipping SwiftUI hosts can report a visibleRect larger
                // than the row. Both checks are needed to target the right item.
                guard self.bounds.contains(point), self.visibleRect.contains(point) else { return event }
                RetroMenuPanel.present(from: self, event: event, actions: self.actions)
                return nil
            }
        }

        func stopObserving() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            if RetroMenuPanel.current?.anchor === self { RetroMenuPanel.current?.dismiss() }
        }
    }
}

@Observable
private final class RetroMenuSelection {
    var index: Int?
}

private struct RetroMenuContent: View {
    let actions: [RetroContextMenuAction]
    let selection: RetroMenuSelection
    let activate: (Int) -> Void

    var body: some View {
        VStack(spacing: 2) {
            ForEach(actions.indices, id: \.self) { index in
                let selected = selection.index == index
                let destructive = actions[index].role == .destructive
                let accent = destructive ? VibeTheme.error : VibeTheme.lcdGreen
                let highlight = destructive ? VibeTheme.error : VibeTheme.lcdDimGreen
                Button(role: actions[index].role) { activate(index) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: actions[index].symbol)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(accent)
                            .frame(width: 16)
                            .accessibilityHidden(true)
                        Text(actions[index].title)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(selected || destructive ? accent : VibeTheme.textPrimary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 29)
                    .background(selected ? highlight.opacity(0.3) : VibeTheme.background)
                    .overlay(Rectangle().stroke(selected ? highlight : .clear, lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    if hovering { selection.index = index }
                    else if selection.index == index { selection.index = nil }
                }
                .accessibilityLabel(actions[index].title)
            }
        }
        .padding(4)
        .frame(width: 210)
        .background(VibeTheme.panel)
        .overlay(Rectangle().strokeBorder(VibeTheme.borderLight, lineWidth: 1))
        .overlay(Rectangle().strokeBorder(VibeTheme.borderDark, lineWidth: 1).padding(1))
        .fixedSize()
    }
}

/// Borderless popup with normal menu dismissal and keyboard navigation. A
/// single active popup prevents orphaned menus when right-clicking another row.
private final class RetroMenuPanel: NSPanel, NSWindowDelegate {
    static var current: RetroMenuPanel?
    weak var anchor: NSView?
    private weak var owner: NSWindow?
    private let actions: [RetroContextMenuAction]
    private let selection = RetroMenuSelection()
    private var monitor: Any?
    private var notifications: [NSObjectProtocol] = []
    private var isDismissing = false

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    private init(anchor: NSView, actions: [RetroContextMenuAction]) {
        self.anchor = anchor
        self.owner = anchor.window
        self.actions = actions
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        hidesOnDeactivate = true
        animationBehavior = .none
        collectionBehavior = [.transient, .fullScreenAuxiliary]
        delegate = self
        setAccessibilityLabel("Menú contextual")

        let hosting = NSHostingView(rootView: RetroMenuContent(actions: actions, selection: selection) { [weak self] index in
            self?.activate(index)
        })
        contentView = hosting
        setContentSize(hosting.fittingSize)
    }

    static func present(from anchor: NSView, event: NSEvent, actions: [RetroContextMenuAction]) {
        guard let window = anchor.window, !actions.isEmpty else { return }
        current?.dismiss()
        let panel = RetroMenuPanel(anchor: anchor, actions: actions)
        current = panel
        let point = window.convertPoint(toScreen: event.locationInWindow)
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? window.screen
        var origin = NSPoint(x: point.x - 8, y: point.y - panel.frame.height + 6)
        if let visible = screen?.visibleFrame.insetBy(dx: 4, dy: 4) {
            origin.x = max(visible.minX, min(origin.x, visible.maxX - panel.frame.width))
            origin.y = max(visible.minY, min(origin.y, visible.maxY - panel.frame.height))
        }
        panel.setFrameOrigin(origin)
        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        // Do not interpret the opening secondary click as an outside click.
        DispatchQueue.main.async { [weak panel] in
            guard let panel, panel.isVisible else { return }
            panel.observeDismissal()
        }
    }

    private func observeDismissal() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .keyDown]) { [weak self] event in
            guard let self, self.isVisible else { return event }
            if event.type == .keyDown, event.window === self || event.window === self.owner {
                switch event.keyCode {
                case 53: self.dismiss(restoreFocus: true) // Escape
                case 125, 48: self.moveSelection(event.modifierFlags.contains(.shift) ? -1 : 1)
                case 126: self.moveSelection(-1)
                case 36, 76, 49:
                    if let index = self.selection.index { self.activate(index) }
                default: return event
                }
                return nil
            }
            if event.window !== self, event.type != .keyDown {
                self.dismiss(restoreFocus: event.type == .leftMouseDown)
                // A dismissing primary click must not accidentally play a song.
                return event.type == .leftMouseDown ? nil : event
            }
            return event
        }
        let center = NotificationCenter.default
        notifications.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main) { [weak self] _ in
            self?.dismiss()
        })
        for name in [NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.willMoveNotification, NSWindow.didResizeNotification] {
            notifications.append(center.addObserver(forName: name, object: owner, queue: .main) { [weak self] _ in
                self?.dismiss()
            })
        }
    }

    private func moveSelection(_ delta: Int) {
        let start = selection.index ?? (delta > 0 ? -1 : 0)
        selection.index = (start + delta + actions.count) % actions.count
    }

    private func activate(_ index: Int) {
        guard actions.indices.contains(index) else { return }
        let action = actions[index].perform
        dismiss(restoreFocus: true)
        action()
    }

    func windowDidResignKey(_ notification: Notification) { dismiss() }

    func dismiss(restoreFocus: Bool = false) {
        guard !isDismissing else { return }
        isDismissing = true
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        notifications.forEach { NotificationCenter.default.removeObserver($0) }
        notifications.removeAll()
        owner?.removeChildWindow(self)
        orderOut(nil)
        if Self.current === self { Self.current = nil }
        if restoreFocus, NSApp.isActive { owner?.makeKey() }
    }
}

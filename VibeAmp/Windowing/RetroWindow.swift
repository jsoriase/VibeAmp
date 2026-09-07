import AppKit
import SwiftUI

/// Borderless-feeling retro panel: custom chrome, sharp geometry, subtle shadow.
/// Uses a titled window with hidden traffic lights so we keep native moving,
/// Spaces, and accessibility while drawing our own Winamp-style header.
final class RetroWindow: NSWindow {
    let role: WindowRole

    init(role: WindowRole, contentView: NSView, frame: NSRect) {
        self.role = role
        super.init(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = false
        hasShadow = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Hide traffic lights; our SwiftUI chrome provides min/shade/close.
        for buttonType: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(buttonType)?.isHidden = true
        }
        // Keep the content view sharp: no rounded corners beyond 2pt.
        contentView.wantsLayer = true
        contentView.layer?.cornerRadius = 2
        contentView.layer?.masksToBounds = true
        self.contentView = contentView
        // Fixed-size panels like the original (shade resizes programmatically).
        // Note: resizable must be false for the user, but shade toggles it briefly.
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// NSView that starts a native window drag for any mouse-down inside it.
/// Used as the background of our custom title bars.
final class WindowDragArea: NSView {
    private var dragOffset: NSPoint?

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        // Manual drag keeps compatibility across SDKs (avoids relying on
        // performWindowDrag) and still feels native for small panels.
        let mouseScreen = NSEvent.mouseLocation
        let origin = window.frame.origin
        dragOffset = NSPoint(x: mouseScreen.x - origin.x, y: mouseScreen.y - origin.y)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let offset = dragOffset else { return }
        let mouseScreen = NSEvent.mouseLocation
        window.setFrameOrigin(NSPoint(x: mouseScreen.x - offset.x, y: mouseScreen.y - offset.y))
    }

    override func mouseUp(with event: NSEvent) {
        dragOffset = nil
    }
}

struct WindowDragGestureView: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowDragArea {
        let view = WindowDragArea()
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }

    func updateNSView(_ nsView: WindowDragArea, context: Context) {}
}

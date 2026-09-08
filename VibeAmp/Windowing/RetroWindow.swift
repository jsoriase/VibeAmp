import AppKit
import SwiftUI

/// Borderless-feeling retro panel: custom chrome, sharp geometry, subtle shadow.
/// Uses a titled window with hidden traffic lights so we keep native moving,
/// Spaces, and accessibility while drawing our own Winamp-style header.
final class RetroWindow: NSWindow {
    let role: WindowRole

    init(role: WindowRole, contentView: NSView, frame: NSRect) {
        self.role = role
        // Borderless, not .titled. A titled window keeps its own title-bar
        // strip above the content view, and AppKit drags the window from there
        // itself — re-anchoring to the window's current position on every
        // event. Any snap correction we applied was therefore undone by the
        // next event, pinning the window within a few points of where the drag
        // started. Owning the gesture is the only way to snap while dragging.
        super.init(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        isMovableByWindowBackground = false
        hasShadow = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Shade collapses to the header height; without this AppKit refuses to
        // shrink a titled window that far.
        minSize = NSSize(width: 200, height: WindowLayout.titleBarHeight)
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

/// Hosting view that responds to the click that also focuses its window.
///
/// SwiftUI views decline `acceptsFirstMouse`, so the first click on an
/// unfocused module was spent activating it: you had to click once to focus a
/// window and only then could you drag it. These are palette windows — the
/// first click should just work.
final class RetroHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

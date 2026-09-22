import SwiftUI
import AppKit

/// Compact custom header resembling classic Winamp: drag to move,
/// minimize / shade / close. Closing a secondary module hides it;
/// closing PLAYER terminates the app.
struct RetroWindowChrome<Content: View>: View {
    let role: WindowRole
    @Environment(WindowManager.self) private var windows
    let content: Content

    init(role: WindowRole, @ViewBuilder content: () -> Content) {
        self.role = role
        self.content = content()
    }

    @State private var isDragging = false

    private var isKey: Bool { windows.isKey(role) }
    private var isShaded: Bool { windows.isShaded(role) }

    var body: some View {
        // The content is given an exact height rather than "whatever's left".
        // A plain VStack lets a too-tall child overflow symmetrically, which
        // pushed the title bar clean off the top of PLAYER and SEARCH; here the
        // bar is always laid out first and any excess is clipped at the bottom.
        GeometryReader { geo in
            ZStack(alignment: .bottomTrailing) {
                VStack(spacing: 0) {
                    titleBar
                        .frame(height: isShaded ? geo.size.height : WindowLayout.titleBarHeight)
                    if !isShaded {
                        content
                            .frame(
                                width: geo.size.width,
                                height: max(0, geo.size.height - WindowLayout.titleBarHeight),
                                alignment: .top
                            )
                            .clipped()
                    }
                }
                if role.isResizable && !isShaded {
                    ResizeGrip(
                        begin: {
                            windows.resizeBegin(role, mouse: NSEvent.mouseLocation)
                        },
                        update: { windows.resizeUpdate(role, mouse: NSEvent.mouseLocation) },
                        end: {
                            windows.resizeEnd(role)
                        }
                    )
                    .padding(2)
                }
            }
        }
        .retroWindowBackground()
    }

    private var titleBar: some View {
        HStack(spacing: 4) {
            TitleBarGrip(active: isKey)
            Text(role.title)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(isKey ? VibeTheme.textPrimary : VibeTheme.textSecondary)
                .tracking(1)
                .lineLimit(1)
                .fixedSize()
                .allowsHitTesting(false)
            TitleBarGrip(active: isKey)
            HStack(spacing: 2) {
                if role == .player {
                    HeaderButton(glyph: .minimize, tooltip: "Hide VibeAmp (click the Dock icon to bring it back)") {
                        windows.minimize(role)
                    }
                }
                HeaderButton(glyph: .shade, tooltip: isShaded ? "Unshade (expand)" : "Shade (collapse)") {
                    windows.toggleShade(role)
                }
                HeaderButton(glyph: .close, tooltip: role == .player ? "Quit VibeAmp" : "Hide window") {
                    windows.close(role)
                }
            }
            .fixedSize()
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isKey ? VibeTheme.panelRaised : VibeTheme.panel)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(VibeTheme.borderLight.opacity(isKey ? 0.45 : 0.2)), alignment: .top)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(VibeTheme.borderDark), alignment: .bottom)
        .contentShape(Rectangle())
        // simultaneousGesture, not gesture: it runs *alongside* the header
        // buttons instead of competing with them, and a 2pt threshold means a
        // click that never moves stays a click. A separate drag layer behind
        // the bar was simply never reached — the buttons' own row consumed the
        // events first.
        .simultaneousGesture(
            DragGesture(minimumDistance: 2)
                .onChanged { _ in
                    // NSEvent.mouseLocation, not the gesture's translation: the
                    // window moves under the pointer as we drag, so the
                    // gesture's coordinate space moves with it and its
                    // translation feeds back on itself.
                    let mouse = NSEvent.mouseLocation
                    if !isDragging {
                        isDragging = true
                        windows.dragBegin(role, mouse: mouse)
                    }
                    windows.dragUpdate(role, mouse: mouse)
                }
                .onEnded { _ in
                    isDragging = false
                    windows.dragEnd(role)
                }
        )
        .onTapGesture(count: 2) {
            windows.toggleShade(role)
        }
        .accessibilityElement(children: .contain)
    }
}

/// Classic diagonal resize hatch. Its hit area is intentionally larger than
/// the three visible rules so it remains easy to grab at small window sizes.
private struct ResizeGrip: View {
    let begin: () -> Void
    let update: () -> Void
    let end: () -> Void

    @State private var active = false
    @State private var hovering = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(VibeTheme.panelRaised.opacity(hovering || active ? 0.95 : 0.75))
            Path { path in
                for offset in stride(from: CGFloat(4), through: 12, by: 4) {
                    path.move(to: CGPoint(x: 16, y: offset))
                    path.addLine(to: CGPoint(x: offset, y: 16))
                }
            }
            .stroke(hovering || active ? VibeTheme.textPrimary : VibeTheme.borderLight, lineWidth: 1)
        }
        .frame(width: 18, height: 18)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !active {
                        active = true
                        begin()
                    }
                    update()
                }
                .onEnded { _ in
                    active = false
                    end()
                }
        )
        .help("Resize window")
        .accessibilityLabel("Resize window")
    }
}

/// Repeating 1px rules that fill the slack either side of the title, giving the
/// bar its striped retro texture and a clear "grab me" affordance.
struct TitleBarGrip: View {
    let active: Bool

    var body: some View {
        VStack(spacing: 2) {
            ForEach(0..<4, id: \.self) { _ in
                Rectangle()
                    .fill(active ? VibeTheme.borderLight : VibeTheme.borderLight.opacity(0.5))
                    .frame(height: 1)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity)
        .frame(height: 10)
        // Sized last: a greedy grip squeezed "VIBEAMP" and "SEARCH & STREAM"
        // down to nothing and pushed the buttons off the bar entirely.
        .layoutPriority(-1)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct HeaderButton: View {
    enum Glyph { case minimize, shade, close }

    let glyph: Glyph
    let tooltip: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            shape
                .frame(width: 16, height: 14)
                .background(hovering ? VibeTheme.borderLight.opacity(0.35) : .clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .accessibilityLabel(tooltip)
        .onHover { hovering = $0 }
    }

    /// Drawn glyphs instead of "_ ▫ X" text: the characters sat on different
    /// baselines and never lined up across the three buttons.
    @ViewBuilder
    private var shape: some View {
        let tint = hovering ? VibeTheme.textPrimary : VibeTheme.textSecondary
        switch glyph {
        case .minimize:
            Rectangle().fill(tint).frame(width: 8, height: 2)
        case .shade:
            Rectangle().stroke(tint, lineWidth: 1).frame(width: 8, height: 6)
        case .close:
            ZStack {
                Rectangle().fill(tint).frame(width: 9, height: 1.5).rotationEffect(.degrees(45))
                Rectangle().fill(tint).frame(width: 9, height: 1.5).rotationEffect(.degrees(-45))
            }
            .frame(width: 9, height: 9)
        }
    }
}

/// Thin retro slider (horizontal). Keyboard-adjustable via native Slider.
struct RetroSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var tooltip: String
    var onChange: ((Double) -> Void)?

    init(value: Binding<Double>, in range: ClosedRange<Double> = 0...1, tooltip: String = "", onChange: ((Double) -> Void)? = nil) {
        self._value = value
        self.range = range
        self.tooltip = tooltip
        self.onChange = onChange
    }

    var body: some View {
        Slider(value: $value, in: range) { _ in }
        .tint(VibeTheme.lcdGreen)
        .help(tooltip)
        .accessibilityLabel(tooltip)
        .onChange(of: value) { _, newValue in onChange?(newValue) }
    }
}

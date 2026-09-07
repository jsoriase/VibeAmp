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

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(role.title)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(VibeTheme.textPrimary)
                    .tracking(1)
                    .lineLimit(1)
                Spacer()
                HeaderButton(label: "_", tooltip: "Minimize") {
                    windows.minimize(role)
                }
                HeaderButton(label: "▫", tooltip: "Shade (collapse)") {
                    windows.toggleShade(role)
                }
                HeaderButton(label: "X", tooltip: role == .player ? "Quit VibeAmp" : "Hide window") {
                    windows.close(role)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(VibeTheme.panelRaised)
            .overlay(Rectangle().frame(height: 1).foregroundStyle(VibeTheme.borderDark), alignment: .bottom)
            .background(WindowDragGestureView())
            .accessibilityElement(children: .contain)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .retroWindowBackground()
    }
}

private struct HeaderButton: View {
    let label: String
    let tooltip: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(VibeTheme.textSecondary)
                .frame(width: 18, height: 14)
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .accessibilityLabel(tooltip)
        .onHover { hovering in
            // Hover brightening handled implicitly by cursor; keep lightweight.
            _ = hovering
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

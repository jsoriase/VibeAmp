import SwiftUI

/// Retro Winamp-inspired palette. Original identity, deliberately not a
/// trademarked pixel clone: charcoal metal, green LCD, restrained amber.
enum VibeTheme {
    static let background = Color(hex: 0x171A1B)
    static let panel = Color(hex: 0x222627)
    static let panelRaised = Color(hex: 0x2D3233)
    static let borderDark = Color(hex: 0x080A0A)
    static let borderLight = Color(hex: 0x4A5152)
    static let lcdBackground = Color(hex: 0x07110A)
    static let lcdGreen = Color(hex: 0x63E26C)
    static let lcdDimGreen = Color(hex: 0x2F7C3C)
    static let accentOrange = Color(hex: 0xE5A52A)
    static let warning = Color(hex: 0xE2B13C)
    static let error = Color(hex: 0xE85D5D)
    static let textPrimary = Color(hex: 0xD7DBD8)
    static let textSecondary = Color(hex: 0x8E9792)

    static func lcdFont(size: CGFloat) -> Font {
        .system(size: size, weight: .medium, design: .monospaced)
    }

    static func smallLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold, design: .default))
            .foregroundStyle(textSecondary)
            .tracking(0.5)
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

/// Sharp retro panel: 1px dark/light bevel, 2pt radius, subtle top highlight.
struct RetroPanel<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .background(VibeTheme.panel)
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .stroke(VibeTheme.borderDark, lineWidth: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .stroke(VibeTheme.borderLight.opacity(0.5), lineWidth: 1)
                    .padding(1)
                    .opacity(0.4)
            )
    }
}

/// Inset LCD well (track display, lists, sliders sit in these).
struct LCDWell<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .background(VibeTheme.lcdBackground)
            .overlay(Rectangle().stroke(VibeTheme.borderDark, lineWidth: 1))
            .overlay(Rectangle().stroke(VibeTheme.borderLight.opacity(0.6), lineWidth: 1).padding(-1).opacity(0))
    }
}

/// Raised retro button with pressed state.
struct RetroButtonStyle: ButtonStyle {
    var active: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(active ? VibeTheme.lcdGreen : VibeTheme.textPrimary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(active ? VibeTheme.panelRaised : VibeTheme.panel)
            .overlay(Rectangle().stroke(configuration.isPressed ? VibeTheme.borderDark : VibeTheme.borderLight, lineWidth: 1))
            .overlay(Rectangle().stroke(configuration.isPressed ? VibeTheme.borderLight : VibeTheme.borderDark, lineWidth: 1).padding(-1).opacity(0.35))
            .opacity(configuration.isPressed ? 0.85 : 1.0)
    }
}

extension View {
    func retroWindowBackground() -> some View {
        background(VibeTheme.background)
            .background(
                // Subtle top highlight for the metallic feel.
                VStack {
                    VibeTheme.borderLight.opacity(0.35).frame(height: 1)
                    Spacer()
                }
            )
    }
}

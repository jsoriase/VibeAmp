import SwiftUI

struct EqualizerView: View {
    @Environment(EQStore.self) private var eq
    @Environment(PlaybackController.self) private var playback
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var eqBindable = eq
        RetroWindowChrome(role: .equalizer) {
            VStack(spacing: 6) {
                HStack(alignment: .bottom, spacing: 0) {
                    EQSlider(label: "PRE", value: $eqBindable.settings.preamp, tooltip: "Preamp gain")
                    ForEach(EQSettings.frequencies, id: \.self) { freq in
                        EQSlider(
                            label: freq >= 1000 ? "\(freq / 1000)K" : "\(freq)",
                            value: Binding(
                                get: { eq.settings.gain(for: freq) },
                                set: { eq.setGain($0, for: freq) }
                            ),
                            tooltip: "\(freq) Hz"
                        )
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.45))
                .overlay(Rectangle().stroke(VibeTheme.borderDark, lineWidth: 1))

                HStack {
                    Text("−12 dB … +12 dB")
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(VibeTheme.textSecondary)
                    Spacer()
                    Button("FLAT") {
                        eq.reset()
                        appState.persistEphemeral()
                        playback.refreshEQ()
                    }
                    .buttonStyle(RetroButtonStyle())
                    .help("Reset equalizer to flat")
                    .accessibilityLabel("Reset equalizer")
                }
            }
            .padding(8)
            .onChange(of: eq.settings) { _, _ in
                // Genuine DSP: rebuild the tap mix + persist (debounced by StateStore).
                playback.refreshEQ()
                appState.persistEphemeral()
            }
        }
        .frame(width: 380, height: 168)
    }
}

private struct EQSlider: View {
    let label: String
    @Binding var value: Double
    let tooltip: String

    var body: some View {
        VStack(spacing: 4) {
            Text(String(format: "%+.0f", value))
                .font(.system(size: 7, design: .monospaced))
                .foregroundStyle(value == 0 ? VibeTheme.textSecondary : VibeTheme.lcdGreen)
                .frame(height: 10)
            Slider(value: $value, in: -12...12, step: 0.5) {
                Text(tooltip)
            }
            .rotationEffect(.degrees(-90))
            .frame(width: 70, height: 20)
            .tint(VibeTheme.lcdGreen)
            .help("\(tooltip): \(String(format: "%+.1f dB", value))")
            .accessibilityLabel("\(tooltip) equalizer band")
            .accessibilityValue("\(String(format: "%+.1f", value)) decibels")
            .frame(height: 70)
            Text(label)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(VibeTheme.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }
}

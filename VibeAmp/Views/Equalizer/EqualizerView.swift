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
                    EQSlider(label: "PRE", value: $eqBindable.settings.preamp, tooltip: "Preamp gain", accent: true)
                    Rectangle()
                        .fill(VibeTheme.borderLight.opacity(0.35))
                        .frame(width: 1)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 3)
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
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.45))
                .overlay(Rectangle().stroke(VibeTheme.borderDark, lineWidth: 1))

                HStack(spacing: 6) {
                    PresetPicker { preset in
                        eq.apply(preset)
                        appState.persistEphemeral()
                        playback.refreshEQ()
                    }
                    Spacer(minLength: 0)
                    Button("FLAT") {
                        eq.reset()
                        appState.persistEphemeral()
                        playback.refreshEQ()
                    }
                    .buttonStyle(RetroButtonStyle())
                    .help("Reset every band to 0 dB")
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Genre curves, listed by name. Shows what the sliders currently sit on, or
/// CUSTOM once they have been moved off a preset.
private struct PresetPicker: View {
    @Environment(EQStore.self) private var eq
    let apply: (EQPreset) -> Void

    var body: some View {
        Menu {
            ForEach(EQPreset.all) { preset in
                Button {
                    apply(preset)
                } label: {
                    // A checkmark marks the curve currently loaded.
                    Text(preset.name == eq.presetName ? "✓ \(preset.name)" : preset.name)
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text("PRESET")
                    .foregroundStyle(VibeTheme.textSecondary)
                Text(eq.presetName)
                    .foregroundStyle(eq.presetName == "CUSTOM" ? VibeTheme.accentOrange : VibeTheme.lcdGreen)
                    .lineLimit(1)
                Text("▾")
                    .foregroundStyle(VibeTheme.textSecondary)
            }
        }
        // .borderlessButton throws the custom label away and draws bare text;
        // .button routes it through the button style like any other control.
        .menuStyle(.button)
        .buttonStyle(RetroButtonStyle())
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Load a genre equalizer preset")
        .accessibilityLabel("Equalizer preset")
        .accessibilityValue(eq.presetName)
    }
}

private struct EQSlider: View {
    let label: String
    @Binding var value: Double
    let tooltip: String
    var accent: Bool = false

    /// Length of the slider's own track, i.e. the column's visible height.
    private let trackLength: CGFloat = 62

    var body: some View {
        VStack(spacing: 3) {
            Text(String(format: "%+.0f", value))
                .font(.system(size: 7, design: .monospaced))
                .foregroundStyle(value == 0 ? VibeTheme.textSecondary : VibeTheme.lcdGreen)
                .frame(height: 9)

            // `rotationEffect` is a render-time transform: it does NOT change
            // the layout footprint. Sizing the slider then rotating it left an
            // n-wide × 20-tall slot per band, so eleven bands demanded ~770pt
            // in a 380pt window and the last six were clipped away. The outer
            // frame declares the real, post-rotation footprint.
            // No label view: SwiftUI renders a Slider's label beside the
            // control, so a labelled slider rotated -90° printed "600 Hz"
            // sideways down every band. The name lives in .accessibilityLabel.
            Slider(value: $value, in: -12...12, step: 0.5)
            .tint(accent ? VibeTheme.accentOrange : VibeTheme.lcdGreen)
            .frame(width: trackLength)
            .rotationEffect(.degrees(-90))
            .frame(width: 18, height: trackLength)
            .help("\(tooltip): \(String(format: "%+.1f dB", value))")
            .accessibilityLabel("\(tooltip) equalizer band")
            .accessibilityValue("\(String(format: "%+.1f", value)) decibels")

            Text(label)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(accent ? VibeTheme.accentOrange : VibeTheme.textSecondary)
                .lineLimit(1)
                .fixedSize()
        }
        .frame(maxWidth: .infinity)
    }
}

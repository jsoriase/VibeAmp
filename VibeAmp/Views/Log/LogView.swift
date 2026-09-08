import SwiftUI

struct LogView: View {
    @Environment(AppLog.self) private var appLog

    var body: some View {
        RetroWindowChrome(role: .log) {
            VStack(spacing: 6) {
                HStack {
                    Text("\(appLog.entries.count) ENTRIES")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(VibeTheme.textSecondary)
                    Spacer()
                    Button("CLEAR") {
                        appLog.clear()
                    }
                    .buttonStyle(RetroButtonStyle())
                    .help("Clear log")
                    .accessibilityLabel("Clear log")
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(appLog.entries) { entry in
                                Text("[\(entry.time)] \(entry.message)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(color(for: entry.level))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(entry.id)
                            }
                        }
                        .padding(4)
                    }
                    .background(Color.black)
                    .overlay(Rectangle().stroke(VibeTheme.borderDark, lineWidth: 1))
                    .onChange(of: appLog.entries.count) { _, _ in
                        if let last = appLog.entries.last {
                            withAnimation(.none) {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }
            }
            .padding(8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func color(for level: LogLevel) -> Color {
        switch level {
        case .info: return VibeTheme.lcdGreen
        case .warning: return VibeTheme.warning
        case .error: return VibeTheme.error
        }
    }
}

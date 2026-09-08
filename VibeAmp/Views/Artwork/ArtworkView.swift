import SwiftUI

struct ArtworkView: View {
    @Environment(PlaybackController.self) private var playback

    var body: some View {
        RetroWindowChrome(role: .art) {
            ZStack {
                Color.black
                if let urlString = playback.currentTrack?.thumbnailURL,
                   !urlString.isEmpty,
                   let url = URL(string: urlString) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .accessibilityLabel("Album artwork")
                        case .failure:
                            placeholder
                        case .empty:
                            ProgressView()
                                .tint(VibeTheme.lcdGreen)
                        @unknown default:
                            placeholder
                        }
                    }
                } else {
                    placeholder
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(Rectangle().stroke(VibeTheme.borderDark, lineWidth: 1))
            .padding(8)
            // AsyncImage uses the shared URLCache: async load, cached, aspect-preserved.
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var placeholder: some View {
        Text("NO ARTWORK")
            .font(VibeTheme.lcdFont(size: 18))
            .foregroundStyle(VibeTheme.lcdDimGreen)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

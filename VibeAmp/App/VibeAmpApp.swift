import SwiftUI
import AppKit

@main
struct VibeAmpApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // Genuine macOS menu-bar mini player: modern system surface,
        // window-style popover. Retro skin stays in the six modules.
        MenuBarExtra("VibeAmp", systemImage: "music.note") {
            MenuBarPopoverView()
                .environment(delegate.appState)
                .environment(delegate.appState.queue)
                .environment(delegate.appState.playback)
                .environment(delegate.appState.eq)
                .environment(delegate.appState.log)
                .environment(delegate.appState.windows)
                .environment(delegate.appState.ytdlp)
        }
        .menuBarExtraStyle(.window)

        Settings {
            EmptyView()
        }
        .commands {
            CommandMenu("Playback") {
                Button("Play/Pause") { delegate.togglePlayPause() }
                    .keyboardShortcut(.space, modifiers: [])
                Button("Next Track") { delegate.appState.step(1) }
                    .keyboardShortcut(.rightArrow, modifiers: [.command])
                Button("Previous Track") { delegate.appState.step(-1) }
                    .keyboardShortcut(.leftArrow, modifiers: [.command])
            }
            CommandMenu("Windows") {
                Button("Open/Focus Search") { delegate.appState.windows.focusSearch() }
                    .keyboardShortcut("f", modifiers: [.command])
                Button("Focus URL Field") { delegate.appState.windows.focusURLField() }
                    .keyboardShortcut("l", modifiers: [.command])
                Button("Toggle Equalizer") { delegate.appState.windows.toggle(.equalizer) }
                    .keyboardShortcut("e", modifiers: [.command])
                Button("Toggle Playlist") { delegate.appState.windows.toggle(.playlist) }
                    .keyboardShortcut("p", modifiers: [.command])
                Button("Toggle Artwork") { delegate.appState.windows.toggle(.art) }
                    .keyboardShortcut("a", modifiers: [.command, .option])
                Divider()
                Button("Show All Windows") { delegate.appState.windows.showAll() }
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        appState.windows.onPlayerClose = { [weak self] in
            self?.terminate()
        }
        Task { @MainActor in
            await appState.startup()
            createWindows()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func createWindows() {
        func hosted<Content: View>(_ view: Content) -> NSView {
            let hosting = NSHostingView(rootView: view
                .environment(appState)
                .environment(appState.queue)
                .environment(appState.playback)
                .environment(appState.eq)
                .environment(appState.log)
                .environment(appState.windows)
                .environment(appState.ytdlp)
            )
            hosting.translatesAutoresizingMaskIntoConstraints = false
            return hosting
        }

        let hosts: [WindowRole: NSView] = [
            .player: hosted(PlayerView()),
            .equalizer: hosted(EqualizerView()),
            .playlist: hosted(PlaylistView()),
            .search: hosted(SearchView()),
            .art: hosted(ArtworkView()),
            .log: hosted(LogView()),
        ]
        appState.windows.createAll(hosts: hosts)
    }

    func togglePlayPause() {
        // Space must not hijack typing in the search field.
        if let first = NSApp.keyWindow?.firstResponder, first is NSText || first is NSTextView {
            return
        }
        appState.playback.toggle()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        appState.persistNow()
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        appState.persistNow()
    }

    private func terminate() {
        appState.persistNow()
        NSApp.terminate(nil)
    }
}

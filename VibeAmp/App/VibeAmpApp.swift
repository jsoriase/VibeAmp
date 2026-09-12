import SwiftUI
import AppKit

@main
struct VibeAmpApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // Genuine macOS menu-bar mini player: modern system surface,
        // window-style popover. Retro skin stays in the retro modules.
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
                Button("Toggle Queue") { delegate.appState.windows.toggle(.playlist) }
                    .keyboardShortcut("p", modifiers: [.command])
                Button("Toggle Playlists") { delegate.appState.windows.toggle(.savedPlaylists) }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Button("Toggle Artwork") { delegate.appState.windows.toggle(.art) }
                    .keyboardShortcut("a", modifiers: [.command, .option])
                Divider()
                Button("Show All Windows") { delegate.appState.windows.showAll() }
                Button("Reset Layout") { delegate.appState.windows.resetLayout() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
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
            let hosting = RetroHostingView(rootView: view
                .environment(appState)
                .environment(appState.queue)
                .environment(appState.playback)
                .environment(appState.eq)
                .environment(appState.log)
                .environment(appState.windows)
                .environment(appState.ytdlp)
                // The window is .titled + .fullSizeContentView, so AppKit hands
                // the hosting view a top safe-area inset the height of a native
                // title bar. That pushed every module's content down under our
                // own retro header — the "double title bar" — and clipped the
                // same amount off the bottom. We draw our own chrome, so we
                // want none of it. Note this has to be done on the SwiftUI side:
                // setting `hosting.safeAreaRegions = []` instead sends AppKit
                // into an endless layout/constraint pass and aborts the app.
                .ignoresSafeArea()
            )
            // WindowManager owns every frame. Left to itself the hosting view
            // pushes its SwiftUI ideal size onto the window as a minimum
            // content size, which silently grew PLAYER to 235pt and EQUALIZER
            // to 200pt and made the docked column overlap itself.
            hosting.sizingOptions = []
            hosting.translatesAutoresizingMaskIntoConstraints = true
            hosting.autoresizingMask = [.width, .height]
            return hosting
        }

        let hosts: [WindowRole: NSView] = [
            .player: hosted(PlayerView()),
            .equalizer: hosted(EqualizerView()),
            .playlist: hosted(PlaylistView()),
            .savedPlaylists: hosted(SavedPlaylistsView(appState: appState)),
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

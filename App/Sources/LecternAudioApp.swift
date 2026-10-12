import AudibleCore
import Sparkle
import SwiftUI

@main
struct LecternAudioApp: App {
    @State private var library = LibraryModel()
    @State private var player = Player()
    @State private var session = AudibleSession()
    private let updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    private var updater: SPUUpdater { updaterController.updater }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(library)
                .environment(player)
                .environment(session)
                .frame(minWidth: 900, minHeight: 560)
                #if DEBUG
                .task {
                    if ProcessInfo.processInfo.environment["LECTERN_CONVERSION_PREVIEW"] == "1", let book = library.selectedBook {
                        library.conversion.book = book
                    }
                    // LECTERN_PLAY=1 plays the selected book, to reproduce player-bar layout issues.
                    if ProcessInfo.processInfo.environment["LECTERN_PLAY"] == "1", let book = library.selectedBook,
                       let url = library.library?.audioURL(for: book) {
                        player.play(book, url: url)
                    }
                    await debugSnapshot()
                    await debugAria2()
                }
                #endif
        }
        .commands { AppCommands(library: library, player: player, session: session, updater: updater) }

        Window("Sign In to Audible", id: SignInView.windowID) {
            SignInView().environment(session)
        }
        .defaultSize(width: 480, height: 720)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView(updater: updater).environment(session)
        }
    }
}

#if DEBUG
/// `LECTERN_SNAPSHOT=/path/out.png` renders the main window to a PNG and quits; no screen-recording permission needed.
/// `LECTERN_SELECT=<asin>` selects a book first.
@MainActor private func debugSnapshot() async {
    let env = ProcessInfo.processInfo.environment
    guard let out = env["LECTERN_SNAPSHOT"] else { return }
    try? await Task.sleep(for: .seconds(1))
    guard let window = NSApp.windows.first else { print("snapshot: no window", NSApp.windows); return }
    window.setFrame(NSRect(x: 0, y: 0, width: 1440, height: 900), display: true)
    try? await Task.sleep(for: .seconds(3))
    let previewSheet = env["LECTERN_CONVERSION_PREVIEW"] == "1" || env["LECTERN_DOWNLOADS_PREVIEW"] == "1"
    let target = previewSheet ? (window.attachedSheet ?? window) : window
    guard let view = target.contentView?.superview else { return }
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
    view.cacheDisplay(in: view.bounds, to: rep)
    do { try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out)) } catch { print("snapshot:", error) }
    NSApp.terminate(nil)
}

/// `LECTERN_ARIA2_TEST=<https URL>` downloads the URL through `ContentDownload` with aria2c, then with URLSession only,
/// prints each duration and quits. Any public range-capable file works; it fails the final audiobook check by design.
@MainActor private func debugAria2() async {
    guard let value = ProcessInfo.processInfo.environment["LECTERN_ARIA2_TEST"], let url = URL(string: value) else { return }
    UserDefaults.standard.register(defaults: [Prefs.aria2: true])
    let directory = FileManager.default.temporaryDirectory.appending(path: "aria2-test")
    let session = URLSession(configuration: .ephemeral)
    for accelerator in [Prefs.aria2Accelerator, nil] {
        try? FileManager.default.removeItem(at: directory)
        let start = ContinuousClock.now
        var outcome = "complete"
        do {
            _ = try await ContentDownload.fetch(url: url, destination: directory.appending(path: "file"),
                                                transfer: { try await session.download(for: $0) }, accelerator: accelerator)
        } catch { outcome = (error as? AudibleError)?.message ?? "\(error)" }
        print("aria2-test", accelerator == nil ? "urlsession" : "aria2c", ContinuousClock.now - start, outcome)
    }
    print("aria2-test log", AppLog.shared.lines)
    NSApp.terminate(nil)
}
#endif

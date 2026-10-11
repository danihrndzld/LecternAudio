import SwiftUI

@main
struct EarmarkApp: App {
    @State private var library = LibraryModel()
    @State private var player = Player()
    @State private var session = AudibleSession()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(library)
                .environment(player)
                .environment(session)
                .frame(minWidth: 900, minHeight: 560)
                #if DEBUG
                .task {
                    if ProcessInfo.processInfo.environment["EARMARK_CONVERSION_PREVIEW"] == "1", let book = library.selectedBook {
                        library.conversion.book = book
                    }
                    // EARMARK_PLAY=1 plays the selected book, to reproduce player-bar layout issues.
                    if ProcessInfo.processInfo.environment["EARMARK_PLAY"] == "1", let book = library.selectedBook,
                       let url = library.library?.audioURL(for: book) {
                        player.play(book, url: url)
                    }
                    await debugSnapshot()
                }
                #endif
        }
        .commands { AppCommands(library: library, player: player, session: session) }

        Window("Sign In to Audible", id: SignInView.windowID) {
            SignInView().environment(session)
        }
        .defaultSize(width: 480, height: 720)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView().environment(session)
        }
    }
}

#if DEBUG
/// `EARMARK_SNAPSHOT=/path/out.png` renders the main window to a PNG and quits; no screen-recording permission needed.
/// `EARMARK_SELECT=<asin>` selects a book first.
@MainActor private func debugSnapshot() async {
    let env = ProcessInfo.processInfo.environment
    guard let out = env["EARMARK_SNAPSHOT"] else { return }
    try? await Task.sleep(for: .seconds(1))
    guard let window = NSApp.windows.first else { print("snapshot: no window", NSApp.windows); return }
    window.setFrame(NSRect(x: 0, y: 0, width: 1440, height: 900), display: true)
    try? await Task.sleep(for: .seconds(3))
    let previewSheet = env["EARMARK_CONVERSION_PREVIEW"] == "1" || env["EARMARK_DOWNLOADS_PREVIEW"] == "1"
    let target = previewSheet ? (window.attachedSheet ?? window) : window
    guard let view = target.contentView?.superview else { return }
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
    view.cacheDisplay(in: view.bounds, to: rep)
    do { try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out)) } catch { print("snapshot:", error) }
    NSApp.terminate(nil)
}
#endif

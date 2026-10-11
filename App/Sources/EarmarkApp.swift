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
                    await debugSnapshot()
                }
                #endif
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open OpenAudible Library…") { library.isPickingFolder = true }
                    .keyboardShortcut("o")
                Button("Reload Library") { library.reload() }
                    .keyboardShortcut("r")
            }
            AccountCommands()
            CommandMenu("Playback") {
                Button(player.isPlaying ? "Pause" : "Play") { player.toggle() }
                    .keyboardShortcut(.space, modifiers: [])
                    .disabled(player.book == nil)
                Button("Back 30 Seconds") { player.skip(-30) }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                Button("Forward 30 Seconds") { player.skip(30) }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
            }
            CommandMenu("Conversion") {
                Button("Convert Selected Book to M4B…") {
                    if let book = library.selectedBook { library.conversion.prepare(book) }
                }
                .disabled(library.selectedBook.flatMap { library.library?.aaxURL(for: $0) } == nil || library.conversion.isRunning)
            }
        }

        Window("Sign In to Audible", id: SignInView.windowID) {
            SignInView().environment(session)
        }
        .defaultSize(width: 480, height: 720)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Settings {
            AccountSettings().environment(session)
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
    let target = env["EARMARK_CONVERSION_PREVIEW"] == "1" ? (window.attachedSheet ?? window) : window
    guard let view = target.contentView?.superview else { return }
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
    view.cacheDisplay(in: view.bounds, to: rep)
    do { try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out)) } catch { print("snapshot:", error) }
    NSApp.terminate(nil)
}
#endif

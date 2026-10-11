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
                .task { await debugSnapshot() }
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
    guard let window = NSApp.windows.first, let view = window.contentView?.superview else { print("snapshot: no window", NSApp.windows); return }
    window.setFrame(NSRect(x: 0, y: 0, width: 1440, height: 900), display: true)
    try? await Task.sleep(for: .seconds(3))
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
    view.cacheDisplay(in: view.bounds, to: rep)
    do { try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out)) } catch { print("snapshot:", error) }
    NSApp.terminate(nil)
}
#endif

import AudibleCore
import os
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
                    await debugPerfCycle(library)
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

/// Body evaluations per view during a perf cycle: `let _ = BodyCount.tick("Name")` at the top of a body.
enum BodyCount {
    static var counts: [String: Int] = [:]
    static func tick(_ name: String) { counts[name, default: 0] += 1 }
}

/// `LECTERN_PERF_CYCLE=N` switches the sidebar filter Finished → All Books N times, prints how long the main thread
/// stays busy after each switch, and quits. Each switch is an os_signpost interval ("All Books", Points of Interest).
/// first = switch until the run loop first goes idle; busy = all main-thread work in the next second; longest = worst span.
@MainActor private func debugPerfCycle(_ library: LibraryModel) async {
    guard let n = ProcessInfo.processInfo.environment["LECTERN_PERF_CYCLE"].flatMap(Int.init), n > 0 else { return }
    final class Spans { var since: ContinuousClock.Instant?; var all: [Duration] = [] }
    let spans = Spans()
    let wake = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, .min) { _, _ in spans.since = .now }
    let idle = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, .max) { _, _ in
        if let since = spans.since { spans.all.append(.now - since) }
        spans.since = nil
    }
    CFRunLoopAddObserver(CFRunLoopGetMain(), wake, .commonModes)
    CFRunLoopAddObserver(CFRunLoopGetMain(), idle, .commonModes)
    // Keep the app out of App Nap even when launched in the background (`open -g`): napping delays the timers.
    let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "perf cycle")
    defer { ProcessInfo.processInfo.endActivity(activity) }
    NSApp.windows.first?.setFrame(NSRect(x: 0, y: 0, width: 1440, height: 900), display: true)
    try? await Task.sleep(for: .seconds(3))
    let signposter = OSSignposter(subsystem: "com.danihrndzld.lecternaudio", category: .pointsOfInterest)
    func ms(_ d: Duration) -> Int { Int(d / .milliseconds(1)) }
    var firsts: [Int] = [], busies: [Int] = [], longests: [Int] = [], bodies: [String: [Int]] = [:]
    for _ in 0..<n {
        library.filter = .finished
        try? await Task.sleep(for: .milliseconds(800))
        let state = signposter.beginInterval("All Books")
        spans.all = []
        spans.since = .now
        BodyCount.counts = [:]
        library.filter = .all
        try? await Task.sleep(for: .seconds(1))
        signposter.endInterval("All Books", state)
        firsts.append(ms(spans.all.first ?? .zero))
        busies.append(ms(spans.all.reduce(.zero, +)))
        longests.append(ms(spans.all.max() ?? .zero))
        for (name, count) in BodyCount.counts { bodies[name, default: []].append(count) }
    }
    func median(_ xs: [Int]) -> Int { xs.sorted()[xs.count / 2] }
    print("perf: Finished → All Books x\(n), \(library.books.count) books, median ms: first \(median(firsts)), busy \(median(busies)), longest \(median(longests))")
    print("perf: body evaluations per switch (median):", bodies.sorted { $0.key < $1.key }.map { "\($0.key) \(median($0.value))" }.joined(separator: ", "))
    print("perf: first \(firsts)\nperf: busy \(busies)\nperf: longest \(longests)")
    fflush(stdout)
    NSApp.terminate(nil)
}
#endif

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
                .task {
                    guard Harness.enabled else { return }
                    if Harness.env["LECTERN_CONVERSION_PREVIEW"] == "1", let book = library.selectedBook {
                        library.conversion.book = book
                    }
                    // LECTERN_PLAY=1 plays the selected book, to reproduce player-bar layout issues.
                    if Harness.env["LECTERN_PLAY"] == "1", let book = library.selectedBook,
                       let url = library.library?.audioURL(for: book) {
                        player.play(book, url: url)
                    }
                    await debugSnapshot()
                    await debugAria2()
                    await debugPerfCycle(library, player)
                }
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

/// Debug knobs (`LECTERN_*` environment variables, see CLAUDE.md). Compiled into every configuration so the perf
/// harness can measure the Release build the owner runs, but inert unless this is a Debug build or the process has
/// `LECTERN_HARNESS=1`.
enum Harness {
    #if DEBUG
    static let enabled = true
    #else
    static let enabled = ProcessInfo.processInfo.environment["LECTERN_HARNESS"] == "1"
    #endif
    static let env: [String: String] = enabled ? ProcessInfo.processInfo.environment : [:]
}

/// `LECTERN_SNAPSHOT=/path/out.png` renders the main window to a PNG and quits; no screen-recording permission needed.
/// `LECTERN_SELECT=<asin>` selects a book first.
@MainActor private func debugSnapshot() async {
    let env = Harness.env
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
    guard let value = Harness.env["LECTERN_ARIA2_TEST"], let url = URL(string: value) else { return }
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
    static func tick(_ name: String) { if Harness.enabled { counts[name, default: 0] += 1 } }
}

extension LibraryFilter {
    /// `LECTERN_PERF_FROM` names: all, downloaded, notConverted, audibleOnly, reading, finished, pdfs, genre:<name>.
    fileprivate init?(perfName: Substring) {
        switch perfName {
        case "all": self = .all
        case "downloaded": self = .downloaded
        case "notConverted": self = .notConverted
        case "audibleOnly": self = .audibleOnly
        case "reading": self = .reading
        case "finished": self = .finished
        case "pdfs": self = .pdfs
        default:
            guard perfName.hasPrefix("genre:") else { return nil }
            self = .genre(String(perfName.dropFirst(6)))
        }
    }
}

/// `LECTERN_PERF_CYCLE=N` switches the sidebar filter N times each way between every `LECTERN_PERF_FROM` filter
/// (comma list, default `finished`; `sort` flips All Books between purchase date and title, `search` types "a" into All Books
/// and clears it) and All Books, prints per transition how long the window takes to settle, and quits.
/// Each switch is an os_signpost interval (Points of Interest) named after the transition.
/// first = switch until the run loop first goes idle; settled = wall clock until the last main-thread span of 2 ms or
/// more (nothing for 400 ms afterwards); busy = all main-thread work until then; longest = worst uninterrupted span.
@MainActor private func debugPerfCycle(_ library: LibraryModel, _ player: Player) async {
    let env = Harness.env
    guard let n = env["LECTERN_PERF_CYCLE"].flatMap(Int.init), n > 0 else { return }
    typealias Transition = (name: String, prepare: () -> Void, go: () -> Void)
    var transitions: [Transition] = []
    for name in (env["LECTERN_PERF_FROM"] ?? "finished").split(separator: ",") {
        switch name {
        case "sort":
            let title = [BookComparator(.title)]
            transitions.append(("All Books: sort Purchased → Title", { library.filter = .all; library.sortOrder = BookComparator.defaultOrder }, { library.sortOrder = title }))
            transitions.append(("All Books: sort Title → Purchased", { library.filter = .all; library.sortOrder = title }, { library.sortOrder = BookComparator.defaultOrder }))
        case "search":
            transitions.append(("All Books: search \"\" → \"a\"", { library.filter = .all; library.search = "" }, { library.search = "a" }))
            transitions.append(("All Books: search \"a\" → \"\"", { library.filter = .all; library.search = "a" }, { library.search = "" }))
        case "scroll":
            // The list's NSTableView (or the grid's scroll view): one page down from the top, and a jump to row 400.
            func scrollView() -> NSScrollView? {
                func find(_ v: NSView) -> NSScrollView? {
                    if let s = v as? NSScrollView, s.documentView is NSTableView || s.frame.width > 400 { return s }
                    for sub in v.subviews { if let s = find(sub) { return s } }
                    return nil
                }
                return NSApp.windows.first?.contentView.flatMap(find)
            }
            func scroll(toRow row: Int) {
                guard let scroll = scrollView() else { return }
                let y = CGFloat(row) * ((scroll.documentView as? NSTableView)?.rowHeight ?? 220)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            transitions.append(("All Books: scroll one page", { library.filter = .all; scroll(toRow: 0) }, { scroll(toRow: 24) }))
            transitions.append(("All Books: scroll to row 400", { library.filter = .all; scroll(toRow: 0) }, { scroll(toRow: 400) }))
        default:
            guard let f = LibraryFilter(perfName: name) else { continue }
            transitions.append(("\(f.title) → All Books", { library.filter = f }, { library.filter = .all }))
            transitions.append(("All Books → \(f.title)", { library.filter = .all }, { library.filter = f }))
        }
    }
    let spans = MainThreadSpans()
    // Wake-ups are seen first and sleeps last (after SwiftUI's own observers commit the update), nested run loops included.
    let wake = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, .min) { _, a in spans.record(a) }
    let sleep = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, .max) { _, a in spans.record(a) }
    CFRunLoopAddObserver(CFRunLoopGetMain(), wake, .commonModes)
    CFRunLoopAddObserver(CFRunLoopGetMain(), sleep, .commonModes)
    // Keep the app out of App Nap even when launched in the background (`open -g`): napping delays the timers.
    let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "perf cycle")
    defer { ProcessInfo.processInfo.endActivity(activity) }
    NSApp.windows.first?.setFrame(NSRect(x: 0, y: 0, width: 1440, height: 900), display: true)
    try? await Task.sleep(for: .seconds(3))
    let signposter = OSSignposter(subsystem: "com.danihrndzld.lecternaudio", category: .pointsOfInterest)
    func ms(_ d: Duration) -> Int { Int(d / .milliseconds(1)) }
    func median(_ xs: [Int]) -> Int { xs.sorted()[xs.count / 2] }
    let mode = env["LECTERN_PERF_LABEL"] ?? (UserDefaults.standard.bool(forKey: "viewMode") ? "grid" : "list")
    for transition in transitions {
        var firsts: [Int] = [], busies: [Int] = [], longests: [Int] = [], settleds: [Int] = [], bodies: [String: [Int]] = [:]
        var counts = (before: 0, after: 0)
        for _ in 0..<n {
            spans.start()
            transition.prepare()
            _ = await spans.settle()
            counts.before = library.visibleBooks.count
            let state = signposter.beginInterval("Filter switch", id: signposter.makeSignpostID(), "\(transition.name)")
            BodyCount.counts = [:]
            spans.start()
            transition.go()
            let result = await spans.settle()
            signposter.endInterval("Filter switch", state)
            counts.after = library.visibleBooks.count
            if env["LECTERN_PERF_TRACE"] != nil, settleds.isEmpty {
                print("perf:   spans ≥ 2 ms (offset ms, length ms):", spans.trace.map { "(\(ms($0.offset)), \(ms($0.length)))" }.joined(separator: " "))
            }
            firsts.append(ms(result.first))
            busies.append(ms(result.busy))
            longests.append(ms(result.longest))
            settleds.append(ms(result.settled))
            for (view, count) in BodyCount.counts { bodies[view, default: []].append(count) }
        }
        print("perf: \(mode) \(transition.name) x\(n), \(counts.before) → \(counts.after) of \(library.books.count) books, median ms: settled \(median(settleds)), first \(median(firsts)), busy \(median(busies)), longest \(median(longests))")
        print("perf:   bodies:", bodies.sorted { $0.key < $1.key }.map { "\($0.key) \(median($0.value))" }.joined(separator: ", "))
        print("perf:   settled \(settleds) first \(firsts) busy \(busies) longest \(longests)")
    }
    library.search = ""
    print("perf: selection after the cycles:", library.selection.sorted(), "sort:", library.sortOrder.map { "\($0.column) \($0.order)" })
    if let book = library.visibleBooks.first {
        // The context menu is built outside the view tree (CLAUDE.md); check that it still builds with its items.
        let menu = NSHostingMenu(rootView: BookActions(book: book, model: library, player: player))
        menu.update()
        print("perf: context menu for \(book.title):", menu.items.map(\.title))
    }
    fflush(stdout)
    NSApp.terminate(nil)
}

/// Main-thread busy spans between run-loop wake-ups and sleeps, read from a background thread so the polling itself
/// doesn't wake the main run loop.
nonisolated private final class MainThreadSpans: @unchecked Sendable {  // guarded by `lock`; read from the poller thread
    private let lock = NSLock()
    private var origin = ContinuousClock.now
    private var busySince: ContinuousClock.Instant?
    private var all: [Duration] = []
    private var lastEnd = ContinuousClock.now
    private(set) var trace: [(offset: Duration, length: Duration)] = []

    /// Called on the main thread for every run-loop activity.
    func record(_ activity: CFRunLoopActivity) {
        let now = ContinuousClock.now
        lock.lock(); defer { lock.unlock() }
        switch activity {
        case .afterWaiting: if busySince == nil { busySince = now }
        case .beforeWaiting:
            if let since = busySince {
                let span = now - since
                all.append(span)
                if span >= .milliseconds(2) { lastEnd = now; trace.append((since - origin, span)) }  // shorter spans are scroller fades and timers, not lag
                busySince = nil
            }
        default: break
        }
    }

    func start() {
        lock.lock(); defer { lock.unlock() }
        origin = .now
        busySince = origin
        lastEnd = origin
        all = []
        trace = []
    }

    /// Waits off the main thread until it has done nothing for 400 ms (at most 20 s). A ping is also dispatched to the
    /// main queue every 25 ms; one answered late marks the main thread busy whatever the observers saw.
    func settle() async -> (first: Duration, busy: Duration, longest: Duration, settled: Duration) {
        let origin = lock.withLock { self.origin }
        await Task.detached(priority: .userInitiated) { [self] in
            while ContinuousClock.now - origin < .seconds(20) {
                try? await Task.sleep(for: .milliseconds(25))
                let sent = ContinuousClock.now
                DispatchQueue.main.async { [self] in
                    let now = ContinuousClock.now
                    if now - sent > .milliseconds(2) { lock.withLock { lastEnd = max(lastEnd, now) } }
                }
                let quietFor = lock.withLock { ContinuousClock.now - (busySince ?? lastEnd) }
                if lock.withLock({ busySince == nil }), quietFor >= .milliseconds(400) { break }
            }
        }.value
        return lock.withLock {
            (all.first ?? .zero, all.reduce(.zero, +), all.max() ?? .zero, max(lastEnd - origin, .zero))
        }
    }
}

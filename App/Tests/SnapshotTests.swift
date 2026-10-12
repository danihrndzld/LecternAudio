import AudibleCore
import SnapshotTesting
import SwiftUI
import Testing
@testable import LecternAudio

/// Snapshots of the main window's states (issue #7). References are PNGs beside this file in
/// `__Snapshots__`, recorded on a developer Mac and not run in CI (the runner draws the glass panels blank);
/// `TEST_RUNNER_LECTERN_RECORD_SNAPSHOTS=1` on the xcodebuild command line records new ones.
///
/// These run in the host app's own defaults domain, so every test puts back what it changes: a test
/// run must not leave the owner's library folder or view mode different from how they left it.
@MainActor
struct SnapshotTests {
    /// Big enough for the sidebar, the list and the inspector together.
    static let size = CGSize(width: 1280, height: 760)

    // MARK: - States

    @Test func libraryTable() throws {
        try withFixture { model in
            withViewMode(grid: false) {
                assert(ContentView().environment(model), named: "table")
            }
        }
    }

    @Test func coverGrid() throws {
        try withFixture { model in
            withViewMode(grid: true) {
                assert(ContentView().environment(model), named: "grid")
            }
        }
    }

    @Test func inspectorWithASelectedBook() throws {
        try withFixture { model in
            model.selection = [model.books.first!.id]
            model.showInspector = true
            withViewMode(grid: false) {
                assert(ContentView().environment(model), named: "inspector")
            }
        }
    }

    @Test func emptyOnboarding() {
        // Not `LibraryModel()`: that restores whatever library this machine last opened, because the
        // test host shares the app's defaults domain.
        #expect(Harness.testHost, "the host app is inert: no restore, no Keychain, no Sparkle")
        let model = LibraryModel(restoring: false)
        #expect(model.books.isEmpty, "no library folder is open")
        assert(ContentView().environment(model), named: "onboarding")
    }

    // MARK: - Harness

    private func assert(_ view: some View, named name: String,
                        _ location: SourceLocation = #_sourceLocation) {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        // A fixed light appearance: the app's appearance setting and the machine's dark mode don't apply.
        window.appearance = NSAppearance(named: .aqua)
        let host = NSHostingView(rootView: view
            .environment(Player())
            .environment(AudibleSession(loadKeychain: false))
            .environment(\.colorScheme, .light)
            .frame(width: Self.size.width, height: Self.size.height))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        // SwiftUI needs a turn of the run loop before a NavigationSplitView has its columns.
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        host.layoutSubtreeIfNeeded()

        withSnapshotTesting(record: ProcessInfo.processInfo.environment["LECTERN_RECORD_SNAPSHOTS"] == "1" ? .all : .missing) {
            // Antialiasing and font rendering differ slightly between machines, so compare
            // perceptually rather than pixel for pixel.
            assertSnapshot(of: host, as: .image(precision: 0.99, perceptualPrecision: 0.97),
                           named: name, fileID: #fileID, file: #filePath,
                           testName: "window", line: UInt(location.line), column: UInt(location.column))
        }
    }

    /// A throwaway OpenAudible folder with a few books, opened without touching the saved bookmark.
    private func withFixture(_ body: (LibraryModel) throws -> Void) throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lectern-snapshots-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(Self.booksJSON.utf8).write(to: folder.appendingPathComponent("books.json"))

        let model = LibraryModel(restoring: false)
        model.open(folder, remember: false)
        #expect(model.books.count == 3, "the fixture folder loaded")
        try body(model)
    }

    /// `viewMode` lives in the host app's defaults, so put the owner's choice back.
    private func withViewMode(grid: Bool, _ body: () -> Void) {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: "viewMode")
        defaults.set(grid, forKey: "viewMode")
        defer {
            if let saved { defaults.set(saved, forKey: "viewMode") } else { defaults.removeObject(forKey: "viewMode") }
        }
        body()
    }

    /// Three books covering the states the table shows: downloaded, encrypted only, and Audible only.
    static let booksJSON = """
    [
      {"asin":"B0SNAP0001","key":"B0SNAP0001","title":"A Downloaded Book","author":"First Author",
       "narrated_by":"First Narrator","publisher":"Test Publisher","genre":"History:World",
       "summary":"A short summary.","seconds":42600,"region":"US","rating_average":"4.7",
       "rating_count":"1200","release_date":"2018-09-04","purchase_date":"2023-08-13",
       "read_status":"Finished","files":[{"path":"a.m4b","type":"M4B"}],"chapters":[]},
      {"asin":"B0SNAP0002","key":"B0SNAP0002","title":"Not Converted Yet","author":"Second Author",
       "narrated_by":"Second Narrator","publisher":"Test Publisher","genre":"Business & Careers:Career Success",
       "summary":"Another summary.","seconds":30960,"region":"US","rating_average":"4.6",
       "rating_count":"900","release_date":"2008-01-01","purchase_date":"2023-09-06",
       "read_status":"Reading","files":[{"path":"b.aax","type":"AAX"}],"chapters":[]},
      {"asin":"B0SNAP0003","key":"B0SNAP0003","title":"Only in Audible","author":"Third Author",
       "narrated_by":"Third Narrator","publisher":"Test Publisher","genre":"History:Europe",
       "summary":"A third summary.","seconds":99000,"region":"US","rating_average":"4.8",
       "rating_count":"150","release_date":"2015-05-05","purchase_date":"2024-01-03",
       "files":[],"chapters":[]}
    ]
    """
}

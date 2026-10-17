import AppKit
import AudibleCore
import Sparkle
import SwiftUI

/// The menu bar. Models are passed in: menus are hosted outside the window tree, so they never read `@Environment` objects.
struct AppCommands: Commands {
    let library: LibraryModel
    let player: Player
    let session: AudibleSession
    let updater: SPUUpdater

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Lectern Audio") {
                AuxWindow.show("about", title: "About Lectern Audio", resizable: false) { AboutView(session: session) }
            }
        }
        AccountCommands()
        FileCommands(library: library, session: session)
        ControlsCommands(library: library, session: session)
        CommandMenu("Actions") {
            if let book = library.selectedBook { BookActions(book: book, model: library, player: player) }
            Button("Download and Convert Selected Books") {
                library.downloads.enqueue(library.books.filter { library.selection.contains($0.id) })
            }
            .disabled(!library.books.contains { library.selection.contains($0.id) && library.canDownload($0) })
        }
        CommandGroup(after: .textEditing) {
            Button("Find") { library.focusSearchRequest += 1 }
                .keyboardShortcut("f")
        }
        PlayerCommands(library: library, player: player)
        ViewCommands(library: library)
        HelpCommands(library: library, session: session, updater: updater)
    }
}

private func functionKey(_ code: Int) -> KeyEquivalent { KeyEquivalent(Character(UnicodeScalar(code)!)) }

private struct FileCommands: Commands {
    let library: LibraryModel
    let session: AudibleSession
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .newItem) {
            SettingsLink { Text("Library Settings…") }
            Menu("Manage Libraries") {
                Button("Open Library Folder…") { library.isPickingFolder = true }
                    .keyboardShortcut("o")
                if !library.recentLibraries.isEmpty {
                    Section("Recent") {
                        ForEach(library.recentLibraries, id: \.self) { bookmark in
                            if let url = LibraryModel.resolve(bookmark) {
                                Button(url.lastPathComponent) { library.open(url) }
                                    .disabled(url.standardizedFileURL == library.library?.root.standardizedFileURL)
                            }
                        }
                    }
                    Button("Clear Recent Libraries") { library.recentLibraries = [] }
                }
            }
            if session.account == nil {
                Button("Manage Accounts…") { openWindow(id: SignInView.windowID) }
            } else {
                SettingsLink { Text("Manage Accounts…") }
            }
            Divider()
            Button("Log Window") {
                AuxWindow.show("log", title: "Log") { LogView(log: .shared) }
            }
            .keyboardShortcut("e")
            Divider()
            Button("Import Books…") { library.importAudio(directory: false) }
            Button("Import Directory…") { library.importAudio(directory: true) }
            Button("Import URL…") { library.importFromURL() }
            Divider()
            Group {
                Button("Export to Excel…") { library.exportList(.xlsx) }
                Button("Export to CSV…") { library.exportList(.csv) }
                Button("Export to JSON…") { library.exportList(.json) }
                Button("Export Cover Art Poster…") { library.exportPoster() }
            }
            .disabled(library.visibleBooks.isEmpty)
            Divider()
            Button("Join Audio Files…") { library.joinAudioFiles() }
                .keyboardShortcut("j")
        }
    }
}

private struct ControlsCommands: Commands {
    let library: LibraryModel
    let session: AudibleSession
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("Controls") {
            Button("Connect to Audible…") { openWindow(id: SignInView.windowID) }
                .keyboardShortcut("k")
                .disabled(session.account != nil)
            // Quick fetches only purchases since the last sync (purchased_after) and merges them into the saved list.
            Button("Quick Library Sync") { sync("Quick sync", quick: true) }
                .keyboardShortcut("r")
                .disabled(session.account == nil || library.isSyncing)
            Button("Full Library Sync") { sync("Full sync") }
                .disabled(session.account == nil || library.isSyncing)
            Divider()
            Button("Download All From Audible…") { library.downloadAll() }
                .disabled(session.account == nil || library.downloadableCount == 0)
            Button("Convert All to M4B…") { library.convertAll() }
                .disabled(session.account == nil || library.convertibleCount == 0 || library.conversion.isRunning)
            Divider()
            Button("Refresh Files") { library.refreshFiles() }
                .keyboardShortcut(functionKey(NSF5FunctionKey), modifiers: [])
            Button("Cancel All Jobs") { library.cancelAllJobs() }
                .disabled(!library.isRunningJobs)
        }
    }

    private func sync(_ name: String, quick: Bool = false) {
        AppLog.shared.info("\(name) requested")
        Task {
            do { library.sync(try await session.currentAccount(), quick: quick) }
            catch { library.syncError = error.localizedDescription }
        }
    }
}

private struct PlayerCommands: Commands {
    let library: LibraryModel
    let player: Player

    var body: some Commands {
        CommandMenu("Player") {
            Button(player.isPlaying ? "Pause" : "Play") {
                if player.book != nil { player.toggle() }
                else if let book = library.selectedBook, let url = library.audioURL(for: book) { player.play(book, url: url) }
            }
            .keyboardShortcut("p")
            .disabled(player.book == nil && library.selectedBook.flatMap(library.audioURL(for:)) == nil)
            Button("Stop") { player.stop() }
                .keyboardShortcut(".")
                .disabled(player.book == nil)
            Divider()
            Group {
                Button("Skip Backward 30 Seconds") { player.skip(-30) }
                    .keyboardShortcut(.leftArrow, modifiers: .option)
                Button("Skip Forward 30 Seconds") { player.skip(30) }
                    .keyboardShortcut(.rightArrow, modifiers: .option)
            }
            .disabled(player.book == nil)
            Divider()
            Group {
                Button("Previous Chapter") { player.previousChapter() }
                    .keyboardShortcut(.upArrow, modifiers: .option)
                Button("Next Chapter") { player.nextChapter() }
                    .keyboardShortcut(.downArrow, modifiers: .option)
                Button("Jump to Chapter Start") { player.chapterStart() }
                    .keyboardShortcut(.pageUp, modifiers: .option)
                Button("Jump to Chapter End") { player.chapterEnd() }
                    .keyboardShortcut(.pageDown, modifiers: .option)
            }
            .disabled(player.book?.chapters.isEmpty ?? true)
            Divider()
            Button("Increase Volume") { player.changeVolume(by: 0.1) }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(player.volume >= 1)
            Button("Decrease Volume") { player.changeVolume(by: -0.1) }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .disabled(player.volume <= 0)
            Divider()
            Button("Show Chapters") {
                guard let book = player.book ?? library.selectedBook else { return }
                library.selection = [book.id]
                library.showInspector = true
                library.showChapters = true
            }
            .disabled(((player.book ?? library.selectedBook)?.chapters.count ?? 0) < 2)
        }
    }
}

enum TableFontSize: String, CaseIterable {
    case small, medium, large

    var font: Font {
        switch self {
        case .small: .system(size: 11)
        case .medium: .system(size: 13)
        case .large: .system(size: 15)
        }
    }
}

private struct ViewCommands: Commands {
    let library: LibraryModel
    @AppStorage(Prefs.tableFontSize) private var fontSize = TableFontSize.medium
    @AppStorage("viewMode") private var gridMode = false
    @AppStorage(Prefs.showGenres) private var showGenres = true

    var body: some Commands {
        CommandGroup(before: .toolbar) {
            Picker("Sort By", selection: Binding(get: { library.sortOrder.first?.column ?? .purchased },
                                                 set: { library.sortOrder = [BookComparator($0, order: library.sortOrder.first?.order ?? .forward)] })) {
                ForEach(BookColumn.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Button("Reverse Sort Direction") {
                if var first = library.sortOrder.first {
                    first.order = first.order == .forward ? .reverse : .forward
                    library.sortOrder = [first]
                }
            }
            Button("Reset Sort") { library.sortOrder = BookComparator.defaultOrder }
                .disabled(library.sortOrder == BookComparator.defaultOrder)
            Picker("Filter By", selection: Binding(get: { library.filter }, set: { library.filter = $0 })) {
                ForEach([LibraryFilter.all, .reading, .finished, .downloaded, .notDownloaded, .notConverted, .unavailable, .pdfs], id: \.self) {
                    Text($0.title).tag($0)
                }
                if showGenres && !library.genres.isEmpty {
                    Divider()
                    ForEach(library.genres, id: \.0) { genre, _ in Text(genre).tag(LibraryFilter.genre(genre)) }
                }
            }
            Toggle("Show Genres", isOn: Binding(get: { showGenres }, set: {
                showGenres = $0
                if !$0, case .genre = library.filter { library.filter = .all }
            }))
            Divider()
            Button("Audiobooks") { library.filter = .all }
                .keyboardShortcut("1")
            // Audible podcasts are not in the synced data yet, so there is nothing to filter.
            Button("Podcasts") {}
                .keyboardShortcut("2")
                .disabled(true)
            Button("Random Book") { library.selectRandomBook() }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(library.visibleBooks.isEmpty)
            Divider()
            Button("Increase Font Size") { step(1) }
                .keyboardShortcut("=")
                .disabled(fontSize == .large)
            Button("Decrease Font Size") { step(-1) }
                .keyboardShortcut("-")
                .disabled(fontSize == .small)
            Button(library.showInspector ? "Hide Inspector" : "Show Inspector") { library.showInspector.toggle() }
                .keyboardShortcut("i")
            Button("Focus Book List") {
                gridMode = false
                library.focusListRequest += 1
            }
            .keyboardShortcut("b", modifiers: [.command, .shift])
            Menu("Table Settings") {
                ForEach(BookColumn.allCases.filter { $0 != .title }, id: \.self) { column in
                    Toggle(column.title, isOn: Binding(
                        get: { library.columnCustomization[visibility: column.rawValue] != .hidden },
                        set: { library.columnCustomization[visibility: column.rawValue] = $0 ? .visible : .hidden }))
                }
            }
            Button("Reset Table") {
                library.columnCustomization = .init()
                library.sortOrder = BookComparator.defaultOrder
                fontSize = .medium
            }
        }
    }

    private func step(_ delta: Int) {
        let all = TableFontSize.allCases
        let i = all.firstIndex(of: fontSize) ?? 1
        fontSize = all[min(all.count - 1, max(0, i + delta))]
    }
}

private struct HelpCommands: Commands {
    let library: LibraryModel
    let session: AudibleSession
    let updater: SPUUpdater

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Lectern Audio Help") { NSWorkspace.shared.open(AppInfo.repo.appending(path: "blob/main/README.md")) }
                .keyboardShortcut(functionKey(NSF1FunctionKey), modifiers: [])
            Button("Lectern Audio Web Page") { NSWorkspace.shared.open(AppInfo.repo) }
            Divider()
            Button("Check for Updates…") { updater.checkForUpdates() }
                .keyboardShortcut("u")
            Button("Send Bug Report…") { NSWorkspace.shared.open(AppInfo.bugReportURL) }
            Button("Diagnostics") {
                AuxWindow.show("diagnostics", title: "Diagnostics") { DiagnosticsView(library: library, session: session) }
            }
        }
    }
}

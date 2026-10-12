import AudibleCore
import SwiftUI

struct ContentView: View {
    @Environment(LibraryModel.self) private var model
    @Environment(AudibleSession.self) private var session
    @Environment(Player.self) private var player
    @AppStorage("viewMode") private var gridMode = false
    @State private var showDownloads = false
    @State private var launched = false
    @AppStorage(Prefs.refreshOnLaunch) private var refreshOnLaunch = true
    @AppStorage(Prefs.autoSync) private var autoSync = true
    @AppStorage(Prefs.autoSyncHours) private var autoSyncHours = 24
    @AppStorage(Prefs.showProgress) private var showProgress = false
    @AppStorage(Prefs.appearance) private var appearance = "system"
    @FocusState private var searchFocused: Bool

    var body: some View {
        let _ = BodyCount.tick("ContentView")
        @Bindable var model = model
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 190, ideal: 220)
        } detail: {
            // Player bar is stacked, not a safeAreaInset: inserting a bottom inset over the AppKit-backed
            // Table changed safe-area insets mid-layout and crashed ("needs update constraints" exception).
            VStack(spacing: 0) {
                Group {
                    if model.books.isEmpty {
                        Onboarding()
                    } else if gridMode {
                        LibraryGrid()
                    } else {
                        LibraryTable()
                    }
                }
                .frame(maxHeight: .infinity)
                if player.book != nil { PlayerBar() }
            }
            .modifier(LibraryTitle(model: model))
        }
        .inspector(isPresented: $model.showInspector) {
            Group {
                if let book = model.selectedBook {
                    BookDetail(book: book)
                } else {
                    ContentUnavailableView("No Selection", systemImage: "book.closed", description: Text("Select a book to see its details."))
                }
            }
            .inspectorColumnWidth(min: 280, ideal: 340, max: 460)
        }
        .searchable(text: $model.search, prompt: "Title, author, narrator")
        .searchFocused($searchFocused)
        // Changes only when ⌘F is pressed, so the extra observation costs one body evaluation.
        .onChange(of: model.focusSearchRequest) { searchFocused = true }
        .toolbar {
            ToolbarItem {
                Button("Downloads", systemImage: "arrow.down.circle") { showDownloads = true }
                    .help("Download queue (\(model.downloads.pendingCount) pending)")
            }
            ToolbarItem {
                ExportsButton(exports: model.exports)
            }
            ToolbarItem {
                Picker("View", selection: $gridMode) {
                    Label("List", systemImage: "list.bullet").tag(false)
                    Label("Covers", systemImage: "square.grid.2x2").tag(true)
                }
                .pickerStyle(.segmented)
            }
            ToolbarItem {
                Button("Sync with Audible", systemImage: "arrow.triangle.2.circlepath") {
                    if let a = session.account { model.sync(a) }
                }
                .help(session.account == nil ? "Sign in to Audible in Settings to sync" : "Sync library from Audible")
                .disabled(session.account == nil || model.isSyncing)
            }
            ToolbarItem {
                Button("Info", systemImage: "info.circle") { model.showInspector.toggle() }
            }
        }
        .onChange(of: session.account?.storageID, initial: true) { _, _ in model.useAudible(session) }
        .task(id: session.account?.deviceSerial) {
            if Harness.env["LECTERN_DOWNLOADS_PREVIEW"] == "1" { showDownloads = true }
            // The first pass is the launch; later passes are sign-ins, which always sync.
            defer { launched = true }
            guard session.account != nil else { return }
            do {
                let account = try await session.currentAccount()
                try Task.checkCancellation()
                model.useAudible(session)
                if refreshOnLaunch || launched { model.sync(account) }
            } catch is CancellationError {
            } catch {
                session.error = "Could not restore the session. Open Account Settings to sign in again."
            }
        }
        .task(id: autoSyncID) { await autoSyncLoop() }
        .onChange(of: model.downloads.activeCount) { old, new in
            if showProgress, old == 0, new > 0 { showDownloads = true }
        }
        .onChange(of: appearance, initial: true) { _, new in applyAppearance(new) }
        .sheet(isPresented: $showDownloads) { DownloadsView(downloads: model.downloads, library: model) }
        .alert("Sync failed", isPresented: Binding { model.syncError != nil } set: { if !$0 { model.syncError = nil } }) {
            Button("OK") {}
        } message: {
            Text(model.syncError ?? "")
        }
        .fileImporter(isPresented: $model.isPickingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { model.open(url) }
        }
        .sheet(isPresented: Binding(get: { model.conversion.book != nil && !model.conversion.isAutomatic }, set: { if !$0 { model.conversion.dismiss() } })) {
            ConversionView(conversion: model.conversion, library: model)
        }
    }

    private var autoSyncHoursOrOff: Int { autoSync ? autoSyncHours : 0 }
    private var autoSyncID: String { "\(session.account?.deviceSerial ?? "")|\(autoSyncHoursOrOff)" }

    /// Syncs every N hours while signed in; restarts when the account or interval changes.
    private func autoSyncLoop() async {
        var last = model.lastSync
        while session.account != nil, let delay = AutoSync.delay(hours: autoSyncHoursOrOff, last: last) {
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            last = .now
            if let account = try? await session.currentAccount() { model.sync(account) }
        }
    }

    private func applyAppearance(_ name: String) {
        NSApp.appearance = name == "system" ? nil : NSAppearance(named: name == "dark" ? .darkAqua : .aqua)
    }
}

/// Reads the filter and visible count in its own body, so switching filters doesn't re-run ContentView's body
/// (and rebuild the table, sidebar and toolbar) just to change the window title.
private struct LibraryTitle: ViewModifier {
    let model: LibraryModel

    func body(content: Content) -> some View {
        content
            .navigationTitle(model.filter.title)
            .navigationSubtitle(model.books.isEmpty ? "" : "\(model.visibleBooks.count) books")
    }
}

private struct Sidebar: View {
    @Environment(LibraryModel.self) private var model

    var body: some View {
        let _ = BodyCount.tick("Sidebar")
        @Bindable var model = model
        List(selection: Binding($model.filter)) {
            Section("Library") {
                row(.all, "books.vertical")
                row(.reading, "headphones")
                row(.finished, "checkmark.circle")
            }
            Section("Files") {
                row(.downloaded, "arrow.down.circle")
                row(.notConverted, "lock")
                row(.audibleOnly, "icloud")
                row(.pdfs, "doc.richtext")
            }
            Section("Genres") {
                ForEach(model.genres, id: \.0) { genre, n in
                    Label(genre, systemImage: "tag").badge(n).tag(LibraryFilter.genre(genre))
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                if !model.books.isEmpty {
                    Text("\(model.books.count) books · \(model.totalHours.formatted()) hours")
                }
                if model.isSyncing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Syncing… \(model.syncedCount) books")
                    }
                } else if let last = model.lastSync {
                    Text("Synced \(last, format: .relative(presentation: .named))")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            // Opaque bar so list rows scrolling underneath don't bleed through the text.
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
    }

    private func row(_ f: LibraryFilter, _ icon: String) -> some View {
        Label(f.title, systemImage: icon).badge(model.count(f)).tag(f)
    }
}

private struct Onboarding: View {
    @Environment(LibraryModel.self) private var model

    var body: some View {
        ContentUnavailableView {
            Label("Open Your Library", systemImage: "books.vertical")
        } description: {
            Text(model.error ?? "Choose the folder that holds OpenAudible's books.json (for example /Volumes/Mac/OpenAudible).")
        } actions: {
            Button("Choose Folder…") { model.isPickingFolder = true }
                .buttonStyle(.borderedProminent)
        }
    }
}


/// Toolbar activity button for the export queue. A leaf view so the counts it reads keep their
/// observation out of `ContentView`'s body (performance rules in CLAUDE.md).
private struct ExportsButton: View {
    let exports: ExportModel
    @State private var showExports = false

    var body: some View {
        let _ = BodyCount.tick("ExportsButton")
        let counts = exports.counts
        let pending = counts.queued + counts.running
        Button {
            showExports = true
        } label: {
            Label("Exports", systemImage: pending > 0 ? "square.and.arrow.up.badge.clock" : "square.and.arrow.up")
        }
        .help(pending > 0 ? "Exports (\(pending) pending)" : "Exports")
        .popover(isPresented: $showExports, arrowEdge: .bottom) { ExportsView(exports: exports) }
        .task {
            exports.seedPreview()
            if Harness.env["LECTERN_EXPORTS_PREVIEW"] == "1" { showExports = true }
        }
    }
}

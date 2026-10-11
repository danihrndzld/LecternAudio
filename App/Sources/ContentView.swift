import AudibleCore
import SwiftUI

struct ContentView: View {
    @Environment(LibraryModel.self) private var model
    @Environment(AudibleSession.self) private var session
    @Environment(Player.self) private var player
    @AppStorage("viewMode") private var gridMode = false
    @State private var showInspector = true

    var body: some View {
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
            .navigationTitle(model.filter.title)
            .navigationSubtitle(model.books.isEmpty ? "" : "\(model.visibleBooks.count) books")
        }
        .inspector(isPresented: $showInspector) {
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
        .toolbar {
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
                Button("Info", systemImage: "info.circle") { showInspector.toggle() }
            }
        }
        .onChange(of: session.account == nil, initial: true) { _, signedOut in model.useAudible(!signedOut) }
        .alert("Sync failed", isPresented: Binding { model.syncError != nil } set: { if !$0 { model.syncError = nil } }) {
            Button("OK") {}
        } message: {
            Text(model.syncError ?? "")
        }
        .fileImporter(isPresented: $model.isPickingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { model.open(url) }
        }
        .sheet(isPresented: Binding(get: { model.conversion.book != nil }, set: { if !$0 { model.conversion.dismiss() } })) {
            ConversionView(conversion: model.conversion, library: model)
        }
    }
}

private struct Sidebar: View {
    @Environment(LibraryModel.self) private var model

    var body: some View {
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

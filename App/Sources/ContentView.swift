import AudibleCore
import SwiftUI

struct ContentView: View {
    @Environment(LibraryModel.self) private var model
    @Environment(Player.self) private var player
    @AppStorage("viewMode") private var gridMode = false
    @State private var showInspector = true

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 190, ideal: 220)
        } detail: {
            Group {
                if model.library == nil {
                    Onboarding()
                } else if gridMode {
                    LibraryGrid()
                } else {
                    LibraryTable()
                }
            }
            .navigationTitle(model.filter.title)
            .navigationSubtitle(model.library == nil ? "" : "\(model.visibleBooks.count) books")
            .safeAreaInset(edge: .bottom) {
                if player.book != nil { PlayerBar() }
            }
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
                Button("Info", systemImage: "info.circle") { showInspector.toggle() }
            }
        }
        .fileImporter(isPresented: $model.isPickingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { model.open(url) }
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
            if model.library != nil {
                Text("\(model.books.count) books · \(model.totalHours.formatted()) hours")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
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

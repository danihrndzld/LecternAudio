import AudibleCore
import SwiftUI

nonisolated extension Book {
    var durationText: String {
        Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .narrow))
    }
}

struct LibraryTable: View {
    @Environment(LibraryModel.self) private var model
    @Environment(Player.self) private var player
    @AppStorage(Prefs.tableFontSize) private var fontSize = TableFontSize.medium
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var model = model
        Table(model.visibleBooks, selection: $model.selection, sortOrder: $model.sortOrder, columnCustomization: $model.columnCustomization) {
            TableColumn("Title", sortUsing: BookComparator(.title)) { b in
                HStack(spacing: 8) {
                    Cover(url: model.thumbURL(for: b), thumbnail: true).frame(width: 28, height: 28)
                    Text(b.title).lineLimit(1)
                }
            }
            .width(min: 200, ideal: 320)
            .customizationID(BookColumn.title.rawValue)
            .disabledCustomizationBehavior(.visibility)
            TableColumn("Author", sortUsing: BookComparator(.author)) { Text($0.author) }
                .width(min: 100, ideal: 160).customizationID(BookColumn.author.rawValue)
            TableColumn("Narrator", sortUsing: BookComparator(.narrator)) { Text($0.narratedBy) }
                .width(min: 100, ideal: 140).customizationID(BookColumn.narrator.rawValue)
            TableColumn("Length", sortUsing: BookComparator(.length)) { Text($0.durationText).monospacedDigit() }
                .width(70).customizationID(BookColumn.length.rawValue)
            TableColumn("Purchased", sortUsing: BookComparator(.purchased)) { b in
                Text(b.purchaseDate?.formatted(date: .abbreviated, time: .omitted) ?? "—")
            }.width(100).customizationID(BookColumn.purchased.rawValue)
            TableColumn("Released", sortUsing: BookComparator(.released)) { b in
                Text(b.releaseDate?.formatted(.dateTime.year()) ?? "—")
            }.width(60).customizationID(BookColumn.released.rawValue)
            TableColumn("Rating", sortUsing: BookComparator(.rating)) { b in
                Text(b.rating.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "—").monospacedDigit()
            }.width(50).customizationID(BookColumn.rating.rawValue)
            TableColumn("Genre", sortUsing: BookComparator(.genre)) { Text($0.primaryGenre) }
                .width(min: 100, ideal: 150).customizationID(BookColumn.genre.rawValue)
            TableColumn("") { b in StatusBadge(book: b) }.width(24).customizationID("status")
        }
        .font(fontSize.font)
        .focused($focused)
        .onChange(of: model.focusListRequest) { focused = true }
        .contextMenu(forSelectionType: Book.ID.self) { ids in
            if let id = ids.first, let b = model.books.first(where: { $0.id == id }) { BookActions(book: b, model: model, player: player) }
        } primaryAction: { ids in
            if let id = ids.first, let b = model.books.first(where: { $0.id == id }) { play(b) }
        }
    }

    private func play(_ b: Book) {
        if let url = model.audioURL(for: b) { player.play(b, url: url) }
    }
}

struct LibraryGrid: View {
    @Environment(LibraryModel.self) private var model
    @Environment(Player.self) private var player

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 20)], spacing: 24) {
                ForEach(model.visibleBooks) { b in
                    VStack(alignment: .leading, spacing: 6) {
                        Cover(url: model.artURL(for: b))
                            .aspectRatio(1, contentMode: .fit)
                            .overlay(alignment: .bottomTrailing) { StatusBadge(book: b).padding(6) }
                            .overlay {
                                if model.selection.contains(b.id) {
                                    RoundedRectangle(cornerRadius: 8).stroke(.tint, lineWidth: 3)
                                }
                            }
                        Text(b.title).font(.callout.weight(.medium)).lineLimit(2)
                        Text(b.author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        if let url = model.audioURL(for: b) { player.play(b, url: url) }
                    }
                    .onTapGesture { model.selection = [b.id] }
                    .contextMenu { BookActions(book: b, model: model, player: player) }
                }
            }
            .padding(24)
        }
    }
}

struct Cover: View {
    let url: URL?
    var thumbnail = false

    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                ZStack {
                    Rectangle().fill(.quaternary)
                    Image(systemName: "book.closed").foregroundStyle(.secondary)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: thumbnail ? 4 : 8))
        .shadow(color: .black.opacity(thumbnail ? 0 : 0.18), radius: 6, y: 3)
    }
}

struct StatusBadge: View {
    let book: Book

    var body: some View {
        if book.hasAudio {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Converted")
        } else if book.hasEncrypted {
            Image(systemName: "lock.circle.fill").foregroundStyle(.orange).help("Downloaded, not converted")
        } else {
            Image(systemName: "icloud").foregroundStyle(.secondary).help("Not downloaded")
        }
    }
}

/// Menus are hosted outside the window's view tree, so dependencies are passed in, not read from the environment.
struct BookActions: View {
    let book: Book
    let model: LibraryModel
    let player: Player

    var body: some View {
        if let url = model.audioURL(for: book) {
            Button("Play", systemImage: "play.fill") { player.play(book, url: url) }
            Button("Show in Finder", systemImage: "folder") { Prefs.reveal(url) }
        }
        if model.library?.aaxURL(for: book) != nil {
            Button("Convert to M4B…", systemImage: "arrow.triangle.2.circlepath") { model.convert(book) }
                .disabled(model.conversion.isRunning)
        }
        if model.canDownload(book) {
            Button("Download and Convert", systemImage: "arrow.down.circle") { model.downloads.enqueue([book]) }
        }
        if model.exports[book.id] != nil {
            Button("Cancel Export", systemImage: "xmark.circle") { model.cancelExport(book.id) }
        } else if model.m4bURL(for: book) != nil {
            Button("Export MP3…", systemImage: "square.and.arrow.up") { model.exportAudio(book, ext: "mp3", byChapter: false) }
            Button("Export MP3 by Chapter…", systemImage: "square.and.arrow.up.on.square") { model.exportAudio(book, ext: "mp3", byChapter: true) }
            Button("Export Ogg Vorbis…", systemImage: "square.and.arrow.up") { model.exportAudio(book, ext: "ogg", byChapter: false) }
            Button("Export Ogg Vorbis by Chapter…", systemImage: "square.and.arrow.up.on.square") { model.exportAudio(book, ext: "ogg", byChapter: true) }
        }
        if let pdf = model.library?.pdfURL(for: book), pdf.pathExtension.lowercased() == "pdf" {
            Button("Open PDF", systemImage: "doc.richtext") { NSWorkspace.shared.open(pdf) }
        }
        if !book.asin.isEmpty, let web = URL(string: "https://www.audible.com/pd/\(book.asin)") {
            Button("View on Audible", systemImage: "safari") { Prefs.open(web, appKey: Prefs.browserApp) }
        }
    }
}

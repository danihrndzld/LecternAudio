import AudibleCore
import ImageIO
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

    var body: some View {
        let _ = BodyCount.tick("LibraryTable")
        // Every model property the table shows is read here, so this body (and the table's update) re-runs when one changes.
        BookTable(model: model, player: player, books: model.visibleBooks, selection: model.selection, sortOrder: model.sortOrder,
                  columns: model.columnCustomization, fontSize: fontSize, focusRequest: model.focusListRequest)
    }
}

struct LibraryGrid: View {
    @Environment(LibraryModel.self) private var model
    @Environment(Player.self) private var player

    var body: some View {
        let _ = BodyCount.tick("LibraryGrid")
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

/// A book cover decoded at display size off the main thread and kept in memory. AsyncImage decoded the full art
/// for every 28 pt row each time the row appeared, and cached nothing.
struct Cover: View {
    let url: URL?
    var thumbnail = false
    @State private var loaded: (url: URL, image: CGImage)?

    var body: some View {
        let _ = BodyCount.tick("Cover")
        let pixels = thumbnail ? CoverCache.thumbnailPixels : 512
        let image = url.flatMap { CoverCache.cached($0, pixels: pixels) } ?? loaded.flatMap { $0.url == url ? $0.image : nil }
        ZStack {
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
            } else {
                Rectangle().fill(.quaternary)
                Image(systemName: "book.closed").foregroundStyle(.secondary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: thumbnail ? 4 : 8))
        .shadow(color: .black.opacity(thumbnail ? 0 : 0.18), radius: thumbnail ? 0 : 6, y: thumbnail ? 0 : 3)
        .task(id: url) {
            guard let url, image == nil, let decoded = await CoverCache.load(url, pixels: pixels) else { return }
            loaded = (url, decoded)
        }
    }
}

/// ImageIO thumbnails shared by `Cover` and the table cells.
nonisolated enum CoverCache {
    static let thumbnailPixels = 96

    /// ~19 MB for every thumbnail of a 500-book library; large covers are evicted first by cost.
    nonisolated(unsafe) private static let cache = {  // NSCache is thread-safe (documented); it's read on main and written off main
        let cache = NSCache<NSString, CGImage>()
        cache.totalCostLimit = 128 << 20
        return cache
    }()

    private static func key(_ url: URL, pixels: Int) -> NSString { "\(pixels) \(url.absoluteString)" as NSString }

    static func cached(_ url: URL, pixels: Int) -> CGImage? { cache.object(forKey: key(url, pixels: pixels)) }

    /// ImageIO thumbnail no larger than `pixels` on its long side (WWDC18 "Image and Graphics Best Practices"), cached.
    @concurrent static func load(_ url: URL, pixels: Int) async -> CGImage? {
        if let image = cached(url, pixels: pixels) { return image }
        let source: CGImageSource?
        if url.isFileURL {
            source = CGImageSourceCreateWithURL(url as CFURL, nil)
        } else {
            guard let data = try? await URLSession.shared.data(from: url).0 else { return nil }
            source = CGImageSourceCreateWithData(data as CFData, nil)
        }
        guard let source, let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels,
        ] as CFDictionary) else { return nil }
        cache.setObject(image, forKey: key(url, pixels: pixels), cost: image.bytesPerRow * image.height)
        return image
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

    /// Right-clicking a book inside a multiple selection acts on the whole selection, as in Finder.
    private var targets: [Book] {
        guard model.selection.count > 1, model.selection.contains(book.id) else { return [book] }
        return model.books.filter { model.selection.contains($0.id) }
    }

    var body: some View {
        if let url = model.audioURL(for: book) {
            Button("Play", systemImage: "play.fill") { player.play(book, url: url) }
            Button("Show in Finder", systemImage: "folder") { Prefs.reveal(url) }
        }
        if model.library?.aaxURL(for: book) != nil {
            Button("Convert to M4B…", systemImage: "arrow.triangle.2.circlepath") { model.convert(book) }
                .disabled(model.conversion.isRunning)
        }
        let downloadable = targets.filter(model.canDownload)
        if !downloadable.isEmpty {
            Button(downloadable.count > 1 ? "Download and Convert \(downloadable.count) Books" : "Download and Convert",
                   systemImage: "arrow.down.circle") { model.downloads.enqueue(downloadable) }
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

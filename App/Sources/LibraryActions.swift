import AVFoundation
import AppKit
import AudibleCore
import SwiftUI
import UniformTypeIdentifiers

/// File menu jobs: import local audio, export the list, the cover poster and joining audio files.
extension LibraryModel {
    private static var importsDirectory: URL { URL.applicationSupportDirectory.appendingPathComponent("Earmark/imports") }
    private static var importsIndex: URL { URL.applicationSupportDirectory.appendingPathComponent("Earmark/imports.json") }
    static let audioTypes: [UTType] = [.mpeg4Audio, .mp3, UTType(filenameExtension: "m4b") ?? .audio]

    private struct ImportRecord: Codable { var bookmark: Data; var book: Book }

    /// Runs a cancellable job; errors are logged and shown, cancellation is silent.
    func runJob(_ name: String, _ body: @escaping @MainActor () async throws -> Void) {
        let id = UUID()
        AppLog.shared.info("\(name) started")
        jobs[id] = Task {
            do {
                try await body()
                AppLog.shared.info("\(name) finished")
            } catch let error where error is CancellationError || Task.isCancelled {
                AppLog.shared.info("\(name) cancelled")
            } catch {
                AppLog.shared.error("\(name) failed: \(error.localizedDescription)")
                NSAlert(error: error).runModal()
            }
            jobs[id] = nil
        }
    }

    // MARK: Import

    func restoreImports() {
        guard let data = try? Data(contentsOf: Self.importsIndex),
              let records = try? JSONDecoder().decode([ImportRecord].self, from: data) else { return }
        var books: [Book] = []
        for record in records {
            var stale = false
            guard let url = (try? URL(resolvingBookmarkData: record.bookmark, options: .withSecurityScope, bookmarkDataIsStale: &stale))
                ?? (try? URL(resolvingBookmarkData: record.bookmark, bookmarkDataIsStale: &stale)) else { continue }
            _ = url.startAccessingSecurityScopedResource()
            importedURLs[record.book.id] = url
            books.append(record.book)
        }
        imported = books
    }

    func saveImports() {
        let records = imported.compactMap { b -> ImportRecord? in
            guard let url = importedURLs[b.id],
                  let bookmark = (try? url.bookmarkData(options: .withSecurityScope)) ?? (try? url.bookmarkData()) else { return nil }
            return ImportRecord(bookmark: bookmark, book: b)
        }
        do {
            try FileManager.default.createDirectory(at: Self.importsIndex.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(records).write(to: Self.importsIndex, options: .atomic)
        } catch { AppLog.shared.error("Could not save imported books: \(error.localizedDescription)") }
    }

    /// File ▸ Import Books / Import Directory: asks for files or a folder, then reads each file's tags with AVFoundation.
    func importAudio(directory: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = !directory
        panel.canChooseDirectories = directory
        panel.allowsMultipleSelection = !directory
        panel.allowedContentTypes = directory ? [.folder] : Self.audioTypes
        panel.prompt = "Import"
        guard panel.runModal() == .OK else { return }
        let picked = panel.urls
        runJob("Import") { [self] in
            var files = picked
            if directory, let folder = picked.first {
                _ = folder.startAccessingSecurityScopedResource()  // kept open: imported files inherit this folder's access
                let extensions: Set = ["m4b", "m4a", "mp3"]
                files = (FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
                    .filter { extensions.contains($0.pathExtension.lowercased()) }
                    .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            }
            try await importFiles(files)
        }
    }

    func importFiles(_ urls: [URL]) async throws {
        var added = 0
        for url in urls {
            try Task.checkCancellation()
            _ = url.startAccessingSecurityScopedResource()
            let book = try await Self.readBook(url)
            imported.removeAll { $0.id == book.id }
            imported.append(book)
            importedURLs[book.id] = url
            added += 1
        }
        saveImports()
        AppLog.shared.info("Imported \(added) file(s)")
    }

    static func readBook(_ url: URL) async throws -> Book {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let metadata = try await asset.load(.commonMetadata)
        func value(_ id: AVMetadataIdentifier) async -> String? {
            try? await AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: id).first?.load(.stringValue)
        }
        var cover: URL?
        if let item = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierArtwork).first,
           let data = try? await item.load(.dataValue), NSImage(data: data) != nil {
            let art = importsDirectory.appendingPathComponent("art")
            try FileManager.default.createDirectory(at: art, withIntermediateDirectories: true)
            cover = art.appendingPathComponent(UUID().uuidString + ".jpg")
            try data.write(to: cover!)
        }
        var chapters: [Chapter] = []
        for group in (try? await asset.loadChapterMetadataGroups(bestMatchingPreferredLanguages: Locale.preferredLanguages)) ?? [] {
            let title = try? await AVMetadataItem.metadataItems(from: group.items, filteredByIdentifier: .commonIdentifierTitle).first?.load(.stringValue)
            chapters.append(Chapter(title: title ?? "Chapter \(chapters.count + 1)",
                                    startMs: Int(group.timeRange.start.seconds * 1000), lengthMs: Int(group.timeRange.duration.seconds * 1000)))
        }
        let title = await value(.commonIdentifierTitle), album = await value(.commonIdentifierAlbumName)
        let artist = await value(.commonIdentifierArtist), author = await value(.commonIdentifierAuthor), genre = await value(.commonIdentifierType)
        return Book(key: "local:" + url.path, title: title ?? album ?? url.deletingPathExtension().lastPathComponent,
                    author: artist ?? author ?? "", genre: genre ?? "", seconds: duration.isFinite ? Int(duration) : 0, imageURL: cover,
                    chapters: chapters, files: [BookFile(path: url.path, type: url.pathExtension.lowercased() == "mp3" ? .mp3 : .m4b)])
    }

    /// File ▸ Import URL: downloads a plain http(s) audio file into Earmark's imports folder. Audible links are refused.
    func importFromURL() {
        let alert = NSAlert()
        alert.messageText = "Import Audio from URL"
        alert.informativeText = "A direct link to an .m4b, .m4a or .mp3 file. Audible books are downloaded from the Downloads queue instead."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = "https://example.com/book.m4b"
        alert.accessoryView = field
        alert.addButton(withTitle: "Import")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let url = URL(string: field.stringValue.trimmingCharacters(in: .whitespaces)), ["http", "https"].contains(url.scheme?.lowercased()),
              let host = url.host()?.lowercased(), !host.contains("audible."), !host.contains("amazon.") else {
            NSAlert(error: AudibleError("Enter an http or https link to an audio file (not an Audible or Amazon link).")).runModal()
            return
        }
        runJob("Import URL") { [self] in
            let (temporary, response) = try await URLSession.shared.download(from: url)
            defer { try? FileManager.default.removeItem(at: temporary) }
            let ext = url.pathExtension.lowercased()
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  response.mimeType?.hasPrefix("audio/") == true || ["m4b", "m4a", "mp3"].contains(ext) else {
                throw AudibleError("That link did not return an audio file.")
            }
            try FileManager.default.createDirectory(at: Self.importsDirectory, withIntermediateDirectories: true)
            let name = url.deletingPathExtension().lastPathComponent.replacing(/[\/:]/, with: "-")
            let target = Self.importsDirectory.appendingPathComponent("\(name)-\(UUID().uuidString.prefix(8)).\(ext.isEmpty ? "m4a" : ext)")
            try FileManager.default.moveItem(at: temporary, to: target)
            try await importFiles([target])
        }
    }

    // MARK: Export

    enum ListFormat: String { case csv, json, xlsx }

    /// File ▸ Export to CSV / JSON / Excel: the books in the current view, in the current sort order.
    func exportList(_ format: ListFormat) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: format.rawValue) ?? .data]
        panel.nameFieldStringValue = "Earmark Library.\(format.rawValue)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let books = visibleBooks
            let data = switch format {
            case .csv: LibraryExport.csv(books)
            case .json: try LibraryExport.json(books)
            case .xlsx: LibraryExport.xlsx(books)
            }
            try data.write(to: url, options: .atomic)
            AppLog.shared.info("Exported \(books.count) books to \(url.lastPathComponent)")
        } catch {
            AppLog.shared.error("Export failed: \(error.localizedDescription)")
            NSAlert(error: error).runModal()
        }
    }

    /// File ▸ Export Cover Art Poster: a square-ish PNG grid of the visible books' covers, 200 px each.
    func exportPoster() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Earmark Covers.png"
        guard panel.runModal() == .OK, let out = panel.url else { return }
        // ponytail: first 400 covers (a 20×20 grid, 4000 px); tile smaller if bigger posters are wanted.
        let urls = visibleBooks.prefix(400).compactMap { b in
            artURL(for: b).flatMap { $0.isFileURL && !FileManager.default.fileExists(atPath: $0.path) ? nil : $0 } ?? b.imageURL
        }
        runJob("Cover poster") { try await Self.renderPoster(urls).write(to: out, options: .atomic) }
    }

    static func renderPoster(_ urls: [URL]) async throws -> Data {
        var images: [NSImage] = []
        for url in urls {
            try Task.checkCancellation()
            let data = url.isFileURL ? try? Data(contentsOf: url) : try? await URLSession.shared.data(from: url).0
            if let data, let image = NSImage(data: data) { images.append(image) }
        }
        guard !images.isEmpty else { throw AudibleError("None of these books has a cover image.") }
        let columns = Int(Double(images.count).squareRoot().rounded(.up))
        let grid = Grid(horizontalSpacing: 0, verticalSpacing: 0) {
            ForEach(Array(stride(from: 0, to: images.count, by: columns)), id: \.self) { start in
                GridRow {
                    ForEach(start..<min(start + columns, images.count), id: \.self) { i in
                        Image(nsImage: images[i]).resizable().scaledToFill().frame(width: 200, height: 200).clipped()
                    }
                }
            }
        }
        .background(.black)
        let renderer = ImageRenderer(content: grid)
        guard let cg = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
            throw AudibleError("Could not render the poster.")
        }
        return png
    }

    // MARK: Join

    /// File ▸ Join Audio Files: concatenates the chosen files (in name order) into one AAC file.
    func joinAudioFiles() {
        let open = NSOpenPanel()
        open.allowsMultipleSelection = true
        open.allowedContentTypes = Self.audioTypes
        open.message = "Choose two or more audio files. They are joined in file-name order."
        open.prompt = "Choose"
        guard open.runModal() == .OK, open.urls.count > 1 else { return }
        let inputs = open.urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let save = NSSavePanel()
        save.allowedContentTypes = [UTType(filenameExtension: "m4b") ?? .mpeg4Audio, .mpeg4Audio]
        save.nameFieldStringValue = inputs[0].deletingPathExtension().lastPathComponent + " (Joined).m4b"
        guard save.runModal() == .OK, let out = save.url else { return }
        runJob("Join \(inputs.count) files") { try await Self.join(inputs, to: out) }
    }

    static func join(_ inputs: [URL], to out: URL) async throws {
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { return }
        var cursor = CMTime.zero
        for url in inputs {
            let asset = AVURLAsset(url: url)
            guard let source = try await asset.loadTracks(withMediaType: .audio).first else {
                throw AudibleError("\(url.lastPathComponent) has no audio.")
            }
            let duration = try await asset.load(.duration)
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: source, at: cursor)
            cursor = cursor + duration
        }
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw AudibleError("This Mac cannot export AAC audio.")
        }
        try? FileManager.default.removeItem(at: out)  // the save panel already confirmed replacing it
        try await session.export(to: out, as: .m4a)
    }
}

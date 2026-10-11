import Foundation

/// Read-only view of an existing OpenAudible library folder
/// (`books.json` plus `books/`, `art/`, `aax/`, `thumb/`).
public struct OpenAudibleLibrary: Sendable {
    public let root: URL
    public let books: [Book]

    public init(root: URL) throws {
        self.root = root
        let data = try Data(contentsOf: root.appendingPathComponent("books.json"))
        var imported = try JSONDecoder().decode([Book].self, from: data)
        let records = try Self.conversions(root: root)
        for index in imported.indices {
            if let path = records[imported[index].id], let output = Self.convertedURL(root: root, path: path),
               FileManager.default.fileExists(atPath: output.path) {
                imported[index].files.insert(BookFile(path: path, type: .m4b), at: 0)
            }
        }
        books = imported
    }

    /// `root/<dir>/<path>`, or nil when `path` (untrusted, from books.json) escapes that folder via `..`, a leading `/` or a symlink.
    public func url(for file: BookFile) -> URL? {
        let name: String = switch file.type {
        case .art: "art"
        case .aax, .aaxc: "aax"
        default: "books"
        }
        guard !file.path.hasPrefix("/") else { return nil }
        let dir = root.appendingPathComponent(name, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        let url = dir.appendingPathComponent(file.path).standardizedFileURL.resolvingSymlinksInPath()
        let base = dir.pathComponents, parts = url.pathComponents
        guard parts.count > base.count, Array(parts.prefix(base.count)) == base else { return nil }
        return url
    }

    public func audioURL(for book: Book) -> URL? {
        book.files.first { $0.type == .m4b || $0.type == .mp3 }.flatMap(url(for:))
    }

    /// Local cover if OpenAudible saved one, else Audible's CDN image (books never downloaded).
    public func artURL(for book: Book) -> URL? {
        book.files.first { $0.type == .art }.flatMap(url(for:)) ?? book.imageURL
    }

    /// Small cover if OpenAudible generated one (often it hasn't), else the full art.
    public func thumbURL(for book: Book) -> URL? {
        guard let art = artURL(for: book), art.isFileURL else { return artURL(for: book) }
        let thumb = root.appendingPathComponent("thumb").appendingPathComponent(art.lastPathComponent)
        return FileManager.default.fileExists(atPath: thumb.path) ? thumb : art
    }

    public func pdfURL(for book: Book) -> URL? {
        book.files.first { $0.type == .pdf }.flatMap(url(for:))
    }

    public func aaxURL(for book: Book) -> URL? {
        book.files.first { $0.type == .aax }.flatMap(url(for:))
    }

    public func conversionOutput(for book: Book) -> URL? {
        guard let input = aaxURL(for: book) else { return nil }
        return root.appendingPathComponent("books/Earmark", isDirectory: true)
            .appendingPathComponent(input.deletingPathExtension().lastPathComponent)
            .appendingPathExtension("m4b")
    }

    public func recordConversion(for book: Book, output: URL) throws {
        let path = "Earmark/" + output.lastPathComponent
        guard let expected = Self.convertedURL(root: root, path: path),
              expected == output.resolvingSymlinksInPath(),
              FileManager.default.fileExists(atPath: output.path) else { throw ConversionError.invalidOutput }
        var records = try Self.conversions(root: root)
        records[book.id] = path
        let data = try JSONEncoder().encode(records)
        try data.write(to: root.appendingPathComponent("earmark-conversions.json"), options: .atomic)
    }

    private static func conversions(root: URL) throws -> [String: String] {
        let url = root.appendingPathComponent("earmark-conversions.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        return try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
    }

    private static func convertedURL(root: URL, path: String) -> URL? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == "Earmark", !parts[1].isEmpty,
              parts[1] != ".", parts[1] != "..", path.lowercased().hasSuffix(".m4b") else { return nil }
        let directory = root.appendingPathComponent("books/Earmark", isDirectory: true).resolvingSymlinksInPath()
        let output = root.appendingPathComponent("books").appendingPathComponent(path).resolvingSymlinksInPath()
        guard output.deletingLastPathComponent() == directory else { return nil }
        return output
    }
}

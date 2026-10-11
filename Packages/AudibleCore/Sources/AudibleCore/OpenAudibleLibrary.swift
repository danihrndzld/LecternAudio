import Foundation

/// Read-only view of an existing OpenAudible library folder
/// (`books.json` plus `books/`, `art/`, `aax/`, `thumb/`).
public struct OpenAudibleLibrary: Sendable {
    public let root: URL
    public let books: [Book]

    public init(root: URL) throws {
        self.root = root
        let data = try Data(contentsOf: root.appendingPathComponent("books.json"))
        books = try JSONDecoder().decode([Book].self, from: data)
    }

    public func url(for file: BookFile) -> URL {
        let dir: String = switch file.type {
        case .art: "art"
        case .aax, .aaxc: "aax"
        default: "books"
        }
        return root.appendingPathComponent(dir).appendingPathComponent(file.path)
    }

    public func audioURL(for book: Book) -> URL? {
        book.files.first { $0.type == .m4b || $0.type == .mp3 }.map(url(for:))
    }

    /// Local cover if OpenAudible saved one, else Audible's CDN image (books never downloaded).
    public func artURL(for book: Book) -> URL? {
        book.files.first { $0.type == .art }.map(url(for:)) ?? book.imageURL
    }

    /// Small cover if OpenAudible generated one (often it hasn't), else the full art.
    public func thumbURL(for book: Book) -> URL? {
        guard let art = artURL(for: book), art.isFileURL else { return artURL(for: book) }
        let thumb = root.appendingPathComponent("thumb").appendingPathComponent(art.lastPathComponent)
        return FileManager.default.fileExists(atPath: thumb.path) ? thumb : art
    }

    public func pdfURL(for book: Book) -> URL? {
        book.files.first { $0.type == .pdf }.map(url(for:))
    }
}

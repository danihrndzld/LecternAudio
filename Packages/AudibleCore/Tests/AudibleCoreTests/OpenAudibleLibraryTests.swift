import Foundation
import Testing
@testable import AudibleCore

@Test func decodesOpenAudibleBooksJSON() throws {
    let root = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
    let lib = try OpenAudibleLibrary(root: root)
    #expect(lib.books.count == 3)

    let book = try #require(lib.books.first { $0.title == "21 Lessons for the 21st Century" })
    #expect(book.seconds > 0)
    #expect(book.rating != nil)
    #expect(!book.chapters.isEmpty)
    #expect(book.hasAudio)
    #expect(lib.audioURL(for: book)?.path.hasSuffix("books/21 Lessons for the 21st Century.m4b") == true)
    #expect(lib.artURL(for: book)?.path.contains("/art/") == true)

    let first = lib.books[0]
    #expect(first.primaryGenre == "Business & Careers")
    #expect(!first.hasAudio)
}

@Test func urlForFileStaysInsideItsFolder() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("earmark-tests-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    try fm.createDirectory(at: root.appendingPathComponent("books/Sub"), withIntermediateDirectories: true)
    try fm.createDirectory(at: root.appendingPathComponent("outside"), withIntermediateDirectories: true)
    try Data("[]".utf8).write(to: root.appendingPathComponent("books.json"))
    try Data().write(to: root.appendingPathComponent("outside/evil.command"))
    try fm.createSymbolicLink(at: root.appendingPathComponent("books/escape"), withDestinationURL: root.appendingPathComponent("outside"))
    try fm.createSymbolicLink(at: root.appendingPathComponent("books/link.m4b"), withDestinationURL: root.appendingPathComponent("outside/evil.command"))
    let lib = try OpenAudibleLibrary(root: root)

    #expect(lib.url(for: BookFile(path: "Book.m4b", type: .m4b))?.lastPathComponent == "Book.m4b")
    #expect(lib.url(for: BookFile(path: "Sub/../Book.m4b", type: .m4b))?.lastPathComponent == "Book.m4b")
    #expect(lib.url(for: BookFile(path: "cover.jpg", type: .art))?.deletingLastPathComponent().lastPathComponent == "art")
    for path in ["../evil.command", "../../etc/passwd", "/etc/passwd", "/../../evil.command", "Sub/../../evil.command",
                 "", ".", "escape/evil.command", "link.m4b"] {
        #expect(lib.url(for: BookFile(path: path, type: .m4b)) == nil, "\(path)")
    }
    #expect(lib.url(for: BookFile(path: "../books/x.pdf", type: .pdf)) != nil)  // back into books/ is still inside
    #expect(lib.url(for: BookFile(path: "../art/x.jpg", type: .pdf)) == nil)
}

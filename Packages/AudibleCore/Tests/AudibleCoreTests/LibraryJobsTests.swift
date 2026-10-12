import Foundation
import Testing
@testable import AudibleCore

private func book(_ asin: String, files: [BookFile] = []) -> Book {
    var b = Book(key: asin, title: asin, author: "A", seconds: 60, files: files)
    b.asin = asin
    return b
}

private let m4b = BookFile(path: "books/a.m4b", type: .m4b)
private let mp3 = BookFile(path: "books/a.mp3", type: .mp3)
private let aax = BookFile(path: "books/a.aax", type: .aax)
private let pdf = BookFile(path: "books/a.pdf", type: .pdf)

@Test func downloadableNeedsOwnershipAndNoLocalFile() {
    let books = [book("B01"), book("B02", files: [m4b]), book("B03", files: [aax]),
                 book("B04"), book("B05", files: [pdf])]
    let owned: Set<String> = ["B01", "B02", "B03", "B05"]
    // B02 already has audio; B03 has an AAX waiting to be converted; B04 is not in the account's catalog.
    #expect(LibraryJobs.downloadable(books, owned: owned).map(\.asin) == ["B01", "B05"])
}

@Test func downloadableTreatsMP3AsAudio() {
    #expect(LibraryJobs.downloadable([book("B01", files: [mp3])], owned: ["B01"]).isEmpty)
}

@Test func convertibleNeedsAnEncryptedFileAndNoAudio() {
    let books = [book("B01", files: [aax]),          // convertible
                 book("B02", files: [aax, m4b]),     // already converted
                 book("B03"),                        // nothing local to convert
                 book("B04", files: [aax])]          // not in the account's catalog
    #expect(LibraryJobs.convertible(books, owned: ["B01", "B02", "B03"]).map(\.asin) == ["B01"])
}

@Test func libraryWideActionsSkipImportedBooks() {
    // An imported local file has no ASIN, so neither action can claim it.
    var imported = Book(key: "local", title: "Local", author: "A", seconds: 60, files: [aax])
    imported.asin = ""
    #expect(LibraryJobs.downloadable([imported], owned: []).isEmpty)
    #expect(LibraryJobs.convertible([imported], owned: [""]).isEmpty)
}

@Test func nothingOwnedMeansNothingToDo() {
    let books = [book("B01"), book("B02", files: [aax])]
    #expect(LibraryJobs.downloadable(books, owned: []).isEmpty)
    #expect(LibraryJobs.convertible(books, owned: []).isEmpty)
}

import Foundation
import Testing
@testable import AudibleCore

private func book(_ title: String, author: String = "A", genre: String = "", seconds: Int = 60,
                  status: ReadStatus? = nil, files: [BookFile] = []) -> Book {
    var b = Book(key: title, title: title, author: author, genre: genre, seconds: seconds, files: files)
    b.readStatus = status
    return b
}

private let library = [
    book("Sapiens", author: "Harari", genre: "History:World", seconds: 300, status: .finished, files: [BookFile(path: "s.m4b", type: .m4b)]),
    book("Dune", author: "Herbert", genre: "Sci-Fi", seconds: 100, files: [BookFile(path: "d.aax", type: .aax)]),
    book("Homo Deus", author: "Harari", genre: "History", seconds: 200, status: .reading),
]

@Test func indexFiltersSearchesAndSortsWhenInputsChange() {
    var index = LibraryIndex()
    #expect(index.visible.isEmpty)
    index.books = library
    #expect(index.visible.map(\.title) == ["Sapiens", "Dune", "Homo Deus"])  // default order: purchase date (all nil)

    index.sortOrder = [BookComparator(.length)]
    #expect(index.visible.map(\.title) == ["Dune", "Homo Deus", "Sapiens"])
    index.filter = .genre("History")
    #expect(index.visible.map(\.title) == ["Homo Deus", "Sapiens"])
    index.search = " sap "
    #expect(index.visible.map(\.title) == ["Sapiens"])
    index.search = "harari"
    index.filter = .all
    #expect(index.visible.map(\.title) == ["Homo Deus", "Sapiens"])

    index.books.append(book("Nexus", author: "Harari", seconds: 150))
    #expect(index.visible.map(\.title) == ["Nexus", "Homo Deus", "Sapiens"])
    index.books.removeAll { $0.title == "Sapiens" }
    #expect(index.visible.map(\.title) == ["Nexus", "Homo Deus"])
}

@Test func indexCountsFiltersAndGenresPerLoad() {
    var index = LibraryIndex()
    #expect(index.count(.all) == 0)
    index.books = library
    #expect(index.count(.all) == 3)
    #expect(index.count(.downloaded) == 1)
    #expect(index.count(.notConverted) == 1)
    #expect(index.count(.audibleOnly) == 1)
    #expect(index.count(.reading) == 1)
    #expect(index.count(.finished) == 1)
    #expect(index.count(.pdfs) == 0)
    #expect(index.count(.genre("History")) == 2)
    #expect(index.genres.map(\.name) == ["History", "Sci-Fi"])
    #expect(index.genres.map(\.count) == [2, 1])

    index.filter = .finished  // filtering never changes the badges
    #expect(index.count(.all) == 3)
    index.books = Array(library.prefix(1))
    #expect(index.genres.map(\.name) == ["History"])
    #expect(index.count(.genre("Sci-Fi")) == 0)
    #expect(index.count(.notConverted) == 0)
}

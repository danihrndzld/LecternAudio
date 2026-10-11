import Foundation
import Testing
@testable import AudibleCore

private let chapters = [
    Chapter(title: "One", startMs: 0, lengthMs: 60_000),
    Chapter(title: "Two", startMs: 60_000, lengthMs: 120_000),
    Chapter(title: "Three", startMs: 180_000, lengthMs: 30_000),
]

@Test func chapterIndexAndNext() {
    #expect(ChapterNavigation.index(at: 0, in: chapters) == 0)
    #expect(ChapterNavigation.index(at: 59.9, in: chapters) == 0)
    #expect(ChapterNavigation.index(at: 60, in: chapters) == 1)
    #expect(ChapterNavigation.index(at: 500, in: chapters) == 2)
    #expect(ChapterNavigation.index(at: 5, in: []) == nil)
    #expect(ChapterNavigation.next(from: 10, in: chapters) == 60)
    #expect(ChapterNavigation.next(from: 60, in: chapters) == 180)
    #expect(ChapterNavigation.next(from: 190, in: chapters) == nil)
}

@Test func previousChapterRestartsAfterGrace() {
    #expect(ChapterNavigation.previous(from: 100, in: chapters) == 60)   // 40 s into Two: restart Two
    #expect(ChapterNavigation.previous(from: 61, in: chapters) == 0)     // 1 s into Two: back to One
    #expect(ChapterNavigation.previous(from: 2, in: chapters) == 0)      // first chapter stays at 0
    #expect(ChapterNavigation.previous(from: 2, in: []) == nil)
}

@Test func chapterBoundsUseNextStartAndCapAtDuration() {
    #expect(ChapterNavigation.bounds(at: 90, in: chapters, duration: 210) == 60...180)
    #expect(ChapterNavigation.bounds(at: 200, in: chapters, duration: 205) == 180...205)
    #expect(ChapterNavigation.bounds(at: 200, in: chapters, duration: 0) == 180...210)
    #expect(ChapterNavigation.bounds(at: 1, in: [], duration: 10) == nil)
}

private func book(_ title: String, author: String = "A", seconds: Int = 60, rating: Double? = nil, purchased: String? = nil) -> Book {
    var b = Book(key: title, title: title, author: author, seconds: seconds, files: [])
    b.rating = rating
    b.purchaseDate = purchased.flatMap(Book.day.date(from:))
    return b
}

@Test func bookComparatorSortsAndReverses() {
    let books = [book("Book 10", seconds: 30, rating: 4.5, purchased: "2024-01-02"),
                 book("Book 9", seconds: 90, purchased: "2025-03-01"),
                 book("alpha", seconds: 60, rating: 3, purchased: nil)]
    #expect(books.sorted(using: BookComparator(.title)).map(\.title) == ["alpha", "Book 9", "Book 10"])
    #expect(books.sorted(using: BookComparator(.title, order: .reverse)).map(\.title) == ["Book 10", "Book 9", "alpha"])
    #expect(books.sorted(using: BookComparator(.length)).map(\.seconds) == [30, 60, 90])
    #expect(books.sorted(using: BookComparator(.rating)).map(\.title) == ["Book 9", "alpha", "Book 10"])
    #expect(books.sorted(using: BookComparator.defaultOrder).map(\.title) == ["Book 9", "Book 10", "alpha"])
}

@Test func updateVersionComparison() {
    #expect(UpdateCheck.isNewer("v0.2.0", than: "0.1.0"))
    #expect(UpdateCheck.isNewer("0.1.10", than: "0.1.9"))
    #expect(UpdateCheck.isNewer("1.0", than: "0.9.9"))
    #expect(!UpdateCheck.isNewer("0.1", than: "0.1.0"))
    #expect(!UpdateCheck.isNewer("v0.1.0-beta", than: "0.1.0"))
    #expect(!UpdateCheck.isNewer("0.0.9", than: "0.1.0"))
    #expect(UpdateCheck.tag(fromRelease: Data(#"{"tag_name":"v1.2.3","name":"x"}"#.utf8)) == "v1.2.3")
    #expect(UpdateCheck.tag(fromRelease: Data(#"{"message":"Not Found"}"#.utf8)) == nil)
}

private let exportBooks: [Book] = {
    var a = book("Dune, Part \"One\"", author: "Frank Herbert", seconds: 3_660, rating: 4.5, purchased: "2024-05-06")
    a.genre = "Sci-Fi:Classics"
    a.asin = "B000000001"
    let b = book("Plain & <Simple>", seconds: 120)
    return [a, b]
}()

@Test func csvQuotesFieldsAndUsesCRLF() throws {
    let csv = try #require(String(data: LibraryExport.csv(exportBooks), encoding: .utf8))
    let lines = csv.components(separatedBy: "\r\n")
    #expect(lines[0] == "Title,Author,Narrator,Length (min),Purchased,Released,Rating,Genre,Publisher,ASIN")
    #expect(lines[1] == #""Dune, Part ""One""",Frank Herbert,,61,2024-05-06,,4.5,Sci-Fi / Classics,,B000000001"#)
    #expect(lines[2] == "Plain & <Simple>,A,,2,,,,,,")
    #expect(lines.count == 4 && lines[3].isEmpty)
}

@Test func jsonKeepsNumbersAsNumbers() throws {
    let objects = try #require(JSONSerialization.jsonObject(with: LibraryExport.json(exportBooks)) as? [[String: Any]])
    #expect(objects.count == 2)
    #expect(objects[0]["Title"] as? String == #"Dune, Part "One""#)
    #expect(objects[0]["Length (min)"] as? Int == 61)
    #expect(objects[0]["Rating"] as? Double == 4.5)
    #expect(objects[1]["Rating"] as? String == "")
}

@Test func xlsxIsAStoredZipWithEscapedSheet() throws {
    let data = LibraryExport.xlsx(exportBooks)
    #expect(data.prefix(4) == Data([0x50, 0x4B, 0x03, 0x04]))
    let text = String(decoding: data, as: UTF8.self)
    for part in ["[Content_Types].xml", "_rels/.rels", "xl/workbook.xml", "xl/_rels/workbook.xml.rels", "xl/worksheets/sheet1.xml"] {
        #expect(text.contains(part))
    }
    #expect(text.contains("<t xml:space=\"preserve\">Plain &amp; &lt;Simple&gt;</t>"))
    #expect(text.contains(#"<c r="D2"><v>61</v></c>"#))
    // End of central directory: 5 entries.
    let eocd = try #require(data.lastRange(of: Data([0x50, 0x4B, 0x05, 0x06])))
    #expect(data[eocd.lowerBound + 10] == 5)
}

@Test func crc32KnownAnswer() {
    #expect(Zip.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
}

@Test func csvNeutralizesFormulas() throws {
    let books = ["=HYPERLINK(\"x\")", "+1", "-2", "@SUM(A1)", "\tx", "\rx", "Safe"].map { book($0) }
    let lines = try #require(String(data: LibraryExport.csv(books), encoding: .utf8)).components(separatedBy: "\r\n")
    #expect(lines[1].hasPrefix(#""'=HYPERLINK(""x"")",A,"#))
    #expect(lines[2].hasPrefix("'+1,"))
    #expect(lines[3].hasPrefix("'-2,"))
    #expect(lines[4].hasPrefix("'@SUM(A1),"))
    #expect(lines[5].hasPrefix("'\tx,"))
    #expect(lines[6].hasPrefix("\"'\rx\","))
    #expect(lines[7].hasPrefix("Safe,"))
}

@Test func fileNameIsOneSafeComponent() {
    #expect(Book.fileName("Dune: Part 1/2", fallback: "B1") == "Dune- Part 1-2")
    #expect(Book.fileName("A\u{0}B\u{1B}C\nD", fallback: "B1") == "ABCD")
    for title in ["", "  ", ".", "..", ".hidden", "\u{7}", "\n.."] {
        #expect(Book.fileName(title, fallback: "B1") == "B1", "\(title)")
    }
    #expect(Book.fileName("../../evil", fallback: "B1") == "B1")
}

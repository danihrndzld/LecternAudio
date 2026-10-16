import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization
import Testing
@testable import AudibleCore

private func fixture(_ name: String) throws -> Data {
    try Data(contentsOf: #require(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)))
}

private func testAccount() throws -> AudibleAccount {
    let key = String(decoding: try fixture("test-only-device-key.pem"), as: UTF8.self)
    return AudibleAccount(marketplace: Marketplace.all[0], deviceSerial: "S", deviceName: "", customerName: "",
                          adpToken: "TEST-ADP-TOKEN", devicePrivateKey: key, accessToken: "", refreshToken: "", expires: .distantPast)
}

private func ok(_ data: Data, _ req: URLRequest) -> (Data, URLResponse) {
    (data, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
}

private actor Log {
    var requests: [URLRequest] = []
    func add(_ r: URLRequest) -> Int { requests.append(r); return requests.count }
}

@Test func pagesUntilShortPage() async throws {
    let pages = [try fixture("library-page1.json"), try fixture("library-page2.json")]
    let log = Log()
    let seen = Mutex<[Int]>([])
    let books = try await AudibleLibrary.fetch(account: testAccount(), pageSize: 2, retryDelay: .zero, send: { req in
        _ = await log.add(req)
        let page = Int(URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "page" }!.value!)!
        return ok(pages[page - 1], req)
    }, progress: { n in seen.withLock { $0.append(n) } })
    #expect(books.map(\.asin) == ["B0BXXXX001", "B0BXXXX002", "B0BXXXX003"])
    #expect(seen.withLock { $0 } == [2, 3])
    let requests = await log.requests
    #expect(requests.count == 2)
    let first = try #require(requests.first)
    #expect(first.url?.host == "api.audible.com")
    #expect(first.url?.path == "/1.0/library")
    let q = Dictionary(uniqueKeysWithValues: URLComponents(url: first.url!, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
    #expect(q["num_results"] == "2")
    #expect(q["response_groups"] == AudibleLibrary.responseGroups)
    #expect(first.value(forHTTPHeaderField: "x-adp-token") == "TEST-ADP-TOKEN")
    #expect(first.value(forHTTPHeaderField: "x-adp-signature")?.hasSuffix("Z") == true)
}

@Test func retriesThenFails() async throws {
    let log = Log()
    let page = try fixture("library-page2.json")
    // Fails twice, then succeeds: one page, three attempts.
    let books = try await AudibleLibrary.fetch(account: testAccount(), retryDelay: .zero, send: { req in
        if await log.add(req) < 3 { throw URLError(.timedOut) }
        return ok(page, req)
    })
    #expect(books.count == 1)

    let failing = Log()
    await #expect(throws: AudibleError.self) {
        _ = try await AudibleLibrary.fetch(account: testAccount(), retryDelay: .zero, send: { req in
            _ = await failing.add(req)
            return (Data(), HTTPURLResponse(url: req.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!)
        })
    }
    #expect(await failing.requests.count == 3)
}

@Test func mapsItemToBook() throws {
    let items = try JSONDecoder().decode(AudibleLibrary.Page.self, from: fixture("library-page1.json")).items
    let b = AudibleLibrary.book(from: items[0], marketplace: Marketplace.all[0])
    #expect(b.asin == "B0BXXXX001")
    #expect(b.title == "Sapiens & Friends")
    #expect(b.author == "Yuval Noah Harari, Second Author")
    #expect(b.narratedBy == "Derek Perkins")
    #expect(b.publisher == "Test Publisher")
    #expect(b.summary == "<p>A <b>summary</b>.</p>")
    #expect(b.seconds == 710 * 60)
    #expect(b.rating == 4.7 && b.ratingCount == 12345)
    #expect(b.genre == "History:World" && b.primaryGenre == "History")
    #expect(b.imageURL?.absoluteString == "https://m.media-amazon.com/images/I/test1._SL500_.jpg")
    #expect(b.releaseDate.map(Book.day.string(from:)) == "2018-09-04")
    #expect(b.purchaseDate.map(Book.day.string(from:)) == "2023-08-13")
    #expect(b.readStatus == .reading)
    #expect(b.region == "US")
    #expect(b.files.isEmpty && !b.hasAudio && !b.hasEncrypted)

    let finished = AudibleLibrary.book(from: items[1], marketplace: Marketplace.all[0])
    #expect(finished.readStatus == .finished)
    #expect(finished.imageURL == nil && finished.genre.isEmpty && finished.narratedBy.isEmpty)

    let page2 = try JSONDecoder().decode(AudibleLibrary.Page.self, from: fixture("library-page2.json")).items
    #expect(AudibleLibrary.book(from: page2[0], marketplace: Marketplace.all[0]).summary == "Only merch summary.")
}

@Test func mergesAudibleListWithLocalFolder() throws {
    let local = try OpenAudibleLibrary(root: #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))).books
    let downloaded = try #require(local.first { $0.hasAudio })
    var remote = AudibleLibrary.book(from: .init(asin: downloaded.asin, title: "Title From Audible"), marketplace: Marketplace.all[0])
    remote.readStatus = nil
    let audibleOnly = AudibleLibrary.book(from: .init(asin: "B0NEW00001", title: "New Purchase"), marketplace: Marketplace.all[0])

    let merged = AudibleLibrary.merge(audible: [remote, audibleOnly], local: local)
    #expect(merged.count == local.count + 1)
    let m = try #require(merged.first { $0.asin == downloaded.asin })
    #expect(m.title == "Title From Audible")
    #expect(m.files == downloaded.files && m.hasAudio)
    #expect(m.chapters == downloaded.chapters)
    #expect(m.key == downloaded.key)
    #expect(m.summary == downloaded.summary)
    let n = try #require(merged.first { $0.asin == "B0NEW00001" })
    #expect(!n.hasAudio && !n.hasEncrypted)  // lands in "Not Downloaded"
    #expect(Set(merged.map(\.id)).count == merged.count)

    #expect(AudibleLibrary.merge(audible: [], local: local) == local)
}

@Test func libraryJSONRoundTrips() throws {
    let local = try OpenAudibleLibrary(root: #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))).books
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("library.json")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try AudibleLibrary.save(local, to: url)
    #expect(AudibleLibrary.load(from: url) == local)
    #expect(AudibleLibrary.load(from: url.appendingPathExtension("missing")).isEmpty)
}

@Test func mergeKeepsOpenAudibleFilesBesideDownload() {
    var openAudible = AudibleLibrary.book(from: .init(asin: "B0BXXXX001", title: "Book"), marketplace: Marketplace.all[0])
    openAudible.files = [BookFile(path: "B0BXXXX001.aax", type: .aax), BookFile(path: "B0BXXXX001.pdf", type: .pdf),
                         BookFile(path: "B0BXXXX001.m4b", type: .m4b)]
    var downloaded = openAudible
    downloaded.files = [BookFile(path: "B0BXXXX001.m4b", type: .m4b)]
    let merged = AudibleLibrary.merge(audible: [openAudible], local: [downloaded])
    #expect(merged.count == 1)
    let files = merged[0].files
    #expect(files.count == 3)
    #expect(Set(files.compactMap(\.type)) == [.m4b, .pdf, .aax])
    #expect(files.first { $0.type == .m4b } == downloaded.files[0])
    #expect(merged[0].hasPDF && merged[0].hasAudio && merged[0].hasEncrypted)
}

@Test func fetchDropsDuplicateASINsFromShiftedPages() async throws {
    // A purchase mid-sync shifts page 2 by one: 002 appears again and is dropped, keeping page 1's copy.
    let pages = [
        #"{"items":[{"asin":"B0BXXXX001","title":"One"},{"asin":"B0BXXXX002","title":"Two"}]}"#,
        #"{"items":[{"asin":"B0BXXXX002","title":"Two again"},{"asin":"B0BXXXX003","title":"Three"}]}"#,
        #"{"items":[]}"#,
    ].map { Data($0.utf8) }
    let books = try await AudibleLibrary.fetch(account: testAccount(), pageSize: 2, retryDelay: .zero, send: { req in
        let page = Int(URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "page" }!.value!)!
        return ok(pages[page - 1], req)
    })
    #expect(books.map(\.asin) == ["B0BXXXX001", "B0BXXXX002", "B0BXXXX003"])
    #expect(books[1].title == "Two")
}

@Test func millisRejectsNonFiniteSeconds() {
    #expect(Chapter.millis(1.5) == 1500)
    #expect(Chapter.millis(0) == 0)
    #expect(Chapter.millis(.nan) == nil)
    #expect(Chapter.millis(.infinity) == nil)
    #expect(Chapter.millis(-.infinity) == nil)
    #expect(Chapter.millis(1e300) == nil)
}

@Test func plusTitleWithoutAPlusPlanIsUnavailable() throws {
    let json = #"""
    {"items": [
      {"asin": "B0PURCHASE", "is_ayce": false, "plans": []},
      {"asin": "B0PLUSLIVE", "is_ayce": true, "plans": [{"plan_name": "US Minerva"}, {"plan_name": "SpecialBenefit"}]},
      {"asin": "B0PLUSGONE", "is_ayce": true, "plans": [{"plan_name": "SpecialBenefit"}]},
      {"asin": "B0PLUSNONE", "is_ayce": true}
    ]}
    """#
    let items = try JSONDecoder().decode(AudibleLibrary.Page.self, from: Data(json.utf8)).items
    let books = items.map { AudibleLibrary.book(from: $0, marketplace: Marketplace.all[0]) }
    #expect(books.map(\.unavailable) == [false, false, true, true])

    // Saved only when true, and read back from the saved catalog.
    let saved = try JSONDecoder().decode([Book].self, from: JSONEncoder().encode(books))
    #expect(saved.map(\.unavailable) == [false, false, true, true])
    #expect(try !String(decoding: JSONEncoder().encode(books[0]), as: UTF8.self).contains("unavailable"))

    var index = LibraryIndex()
    index.books = books
    #expect(index.count(.unavailable) == 2)
    #expect(index.count(.notDownloaded) == 2)
    // Unavailable and Not Downloaded split the books with no file between them.
    #expect(books.filter { LibraryFilter.unavailable.matches($0) != LibraryFilter.notDownloaded.matches($0) }.count == books.count)
    #expect(LibraryJobs.downloadable(books, owned: Set(books.map(\.asin))).map(\.asin) == ["B0PURCHASE", "B0PLUSLIVE"])
}

@Test func companionPDFIsFlaggedSavedAndRequestedSigned() throws {
    let json = #"""
    {"items": [
      {"asin": "B0BXXXX001", "pdf_url": null},
      {"asin": "B0BXXXX002"},
      {"asin": "B0BXXXX003", "pdf_url": "https://www.audible.com/companion-file/B0BXXXX003"}
    ]}
    """#
    let items = try JSONDecoder().decode(AudibleLibrary.Page.self, from: Data(json.utf8)).items
    let books = items.map { AudibleLibrary.book(from: $0, marketplace: Marketplace.all[0]) }
    #expect(books.map(\.hasCompanionPDF) == [false, false, true])

    // Saved only when true, so queue.json and library.json written before it still decode.
    let saved = try JSONDecoder().decode([Book].self, from: JSONEncoder().encode(books))
    #expect(saved.map(\.hasCompanionPDF) == [false, false, true])
    #expect(try !String(decoding: JSONEncoder().encode(books[0]), as: UTF8.self).contains("companion_pdf"))

    let account = try testAccount()
    let request = try AudibleLibrary.companionPDFRequest(asin: "B0BXXXX003", account: account)
    #expect(request.url?.absoluteString == "https://www.audible.\(account.marketplace.domain)/companion-file/B0BXXXX003")
    #expect(request.value(forHTTPHeaderField: "x-adp-signature") != nil)
    #expect(request.value(forHTTPHeaderField: "Accept") == "*/*")
    #expect(throws: AudibleError.self) { try AudibleLibrary.companionPDFRequest(asin: "../x", account: account) }

    #expect(AudibleLibrary.isPDF(Data("%PDF-1.7\n".utf8)))
    #expect(!AudibleLibrary.isPDF(Data("<html>".utf8)))
    #expect(!AudibleLibrary.isPDF(Data()))
}

@Test func downloadedPDFIsFoundBesideTheBook() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root.appendingPathComponent("books"), withIntermediateDirectories: true)
    try Data("%PDF".utf8).write(to: root.appendingPathComponent("books/B0BXXXX003.pdf"))
    var book = Book(key: "k", title: "T", author: "A", seconds: 1, files: [BookFile(path: "B0BXXXX003.m4b", type: .m4b)])
    book.asin = "B0BXXXX003"
    book.files.append(BookFile(path: "B0BXXXX003.pdf", type: .pdf))
    try AudibleLibrary.save([book], to: root.appendingPathComponent("books.json"))
    let library = try OpenAudibleLibrary(root: root)
    #expect(library.books[0].hasPDF)
    #expect(library.pdfURL(for: library.books[0])?.path == root.appendingPathComponent("books/B0BXXXX003.pdf").resolvingSymlinksInPath().path)
}

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
    #expect(!n.hasAudio && !n.hasEncrypted)  // lands in "In Audible Only"
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

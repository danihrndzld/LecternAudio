import Foundation
import Testing
@testable import AudibleCore

/// Issue #47, PR 1: AudibleCore merges several accounts' catalogs. The app still signs in to one
/// account, so every test here drives the core directly.

private func marketplace(_ code: String) -> Marketplace { Marketplace.all.first { $0.code == code }! }

private func fixture(_ name: String, _ code: String = "us") throws -> [Book] {
    let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "json")!
    let page = try JSONDecoder().decode(AudibleLibrary.Page.self, from: Data(contentsOf: url))
    return page.items.map { AudibleLibrary.book(from: $0, marketplace: marketplace(code)) }
}

private func book(_ asin: String, status: ReadStatus? = nil, title: String = "T") -> Book {
    var b = Book(key: asin, title: title, author: "A", seconds: 60, files: [])
    b.asin = asin
    b.readStatus = status
    return b
}

// MARK: - One account behaves exactly as before

@Test func oneAccountOnlyTagsTheOwner() throws {
    let us = try fixture("library-page1")
    let merged = AudibleLibrary.merge(accounts: [.init(id: "acct-us", books: us)])
    #expect(merged.map(\.asin) == us.map(\.asin), "order and membership unchanged")
    #expect(merged.allSatisfy { $0.accountIDs == ["acct-us"] })
    // Metadata is untouched, so the single-account app sees no change.
    for (before, after) in zip(us, merged) {
        var tagged = before
        tagged.accountIDs = ["acct-us"]
        #expect(after == tagged)
    }
}

@Test func noAccountsMergeToNothing() {
    #expect(AudibleLibrary.merge(accounts: []).isEmpty)
    #expect(AudibleLibrary.merge(accounts: [.init(id: "a", books: [])]).isEmpty)
}

// MARK: - Owners accumulate, first account wins the metadata

@Test func overlappingBooksCollectBothOwners() throws {
    let us = try fixture("library-page1"), es = try fixture("library-account-es", "es")
    let merged = AudibleLibrary.merge(accounts: [.init(id: "us", books: us), .init(id: "es", books: es)])

    // Both of page1's books are also in the ES catalog, which adds two of its own.
    #expect(merged.map(\.asin) == ["B0BXXXX001", "B0BXXXX002", "B0BXXXX101", "B0BXXXX102"])
    #expect(merged[0].accountIDs == ["us", "es"])
    #expect(merged[1].accountIDs == ["us", "es"])
    #expect(merged[2].accountIDs == ["es"], "a book only the second account owns")
    #expect(merged[3].accountIDs == ["es"])
}

@Test func theFirstAccountSuppliesTheMetadata() throws {
    let us = try fixture("library-page1"), es = try fixture("library-account-es", "es")
    let usFirst = AudibleLibrary.merge(accounts: [.init(id: "us", books: us), .init(id: "es", books: es)])
    let esFirst = AudibleLibrary.merge(accounts: [.init(id: "es", books: es), .init(id: "us", books: us)])

    // The same book, different narrator and publisher per marketplace: sign-in order decides.
    #expect(usFirst[0].narratedBy == "Derek Perkins")
    #expect(esFirst.first { $0.asin == "B0BXXXX001" }?.narratedBy == "Narrador de Prueba")
    // Reversing the order also reverses the owner order and moves the ES-only books to the front.
    #expect(esFirst.map(\.asin) == ["B0BXXXX001", "B0BXXXX002", "B0BXXXX101", "B0BXXXX102"])
    #expect(esFirst[0].accountIDs == ["es", "us"])
}

@Test func anOwnerIsNeverListedTwice() {
    // The same account appearing twice (a re-sync appending to the list) must not double-count.
    let merged = AudibleLibrary.merge(accounts: [.init(id: "a", books: [book("B01")]),
                                                 .init(id: "a", books: [book("B01")])])
    #expect(merged.count == 1)
    #expect(merged[0].accountIDs == ["a"])
}

// MARK: - Read status is the furthest of the accounts

@Test func finishedInEitherAccountWins() throws {
    let us = try fixture("library-page1"), es = try fixture("library-account-es", "es")
    let merged = AudibleLibrary.merge(accounts: [.init(id: "us", books: us), .init(id: "es", books: es)])
    // B0BXXXX001: listening in US, finished in ES. B0BXXXX002: finished in US, unread in ES.
    #expect(merged[0].readStatus == .finished, "finished in the second account wins")
    #expect(merged[1].readStatus == .finished, "finished in the first account is not lost")
}

@Test func furthestReadStatus() {
    #expect(AudibleLibrary.furthest(.reading, .finished) == .finished)
    #expect(AudibleLibrary.furthest(.finished, nil) == .finished)
    #expect(AudibleLibrary.furthest(nil, .reading) == .reading)
    #expect(AudibleLibrary.furthest(.unread, .reading) == .reading)
    #expect(AudibleLibrary.furthest(nil, nil) == nil)
    #expect(AudibleLibrary.furthest(.unread, nil) == .unread)
    #expect(AudibleLibrary.furthest(.wantToRead, .unread) == .wantToRead, "neither is further: the first owner's")
}

// MARK: - Ownership is derived, never written to disk

@Test func accountIDsAreNotEncoded() throws {
    var b = book("B0BXXXX001", title: "Owned")
    b.accountIDs = ["us", "es"]
    let data = try JSONEncoder().encode([b])
    let json = String(decoding: data, as: UTF8.self)
    #expect(!json.contains("accountIDs"))
    #expect(!json.contains("\"us\""))
    // A catalog written with owners and read back has none: they are recomputed by the next merge.
    let back = try JSONDecoder().decode([Book].self, from: data)
    #expect(back[0].accountIDs.isEmpty)
    #expect(back[0].title == "Owned", "the rest of the book still round-trips")
}

@Test func legacyQueueFileDecodesWithoutAnOwner() throws {
    // queue.json written before multiple accounts: no accountID field at all.
    let legacy = """
    [{"book":{"asin":"B0BXXXX001","key":"B0BXXXX001","title":"T","author":"A","narrated_by":"","publisher":"",\
    "genre":"","summary":"","seconds":60,"region":"","chapters":[],"files":[]},"state":"queued"}]
    """
    let jobs = try DownloadJob.restore(from: Data(legacy.utf8))
    #expect(jobs.count == 1)
    #expect(jobs[0].accountID == nil)
    #expect(jobs[0].state == .queued)
}

@Test func aQueueWithoutOwnersKeepsItsFormat() throws {
    let job = DownloadJob(book: book("B0BXXXX001"), state: .queued)
    let json = String(decoding: try JSONEncoder().encode([job]), as: UTF8.self)
    #expect(!json.contains("accountID"), "nil is omitted, so single-account files are unchanged")
}

@Test func anOwnedJobRoundTrips() throws {
    let job = DownloadJob(book: book("B0BXXXX001"), state: .queued, accountID: "es")
    let back = try DownloadJob.restore(from: try JSONEncoder().encode([job]))
    #expect(back[0].accountID == "es")
}

// MARK: - The index filters and counts by account

@Test func indexFiltersAndCountsByAccount() throws {
    let us = try fixture("library-page1"), es = try fixture("library-account-es", "es")
    var index = LibraryIndex()
    index.books = AudibleLibrary.merge(accounts: [.init(id: "us", books: us), .init(id: "es", books: es)])

    #expect(index.count(.account("us")) == 2)
    #expect(index.count(.account("es")) == 4)
    #expect(index.count(.account("nobody")) == 0)
    #expect(index.count(.all) == 4)

    index.filter = .account("es")
    #expect(index.visible.count == 4)
    index.filter = .account("us")
    #expect(Set(index.visible.map(\.asin)) == ["B0BXXXX001", "B0BXXXX002"])
}

@Test func accountsAreNotGenresAndGenresAreNotAccounts() throws {
    var index = LibraryIndex()
    var b = book("B01")
    b.genre = "History:World"
    b.accountIDs = ["History"]  // an account id that collides with a genre name
    index.books = [b]
    #expect(index.genres.map(\.name) == ["History"])
    #expect(index.genres.map(\.count) == [1])
    #expect(index.count(.genre("History")) == 1)
    #expect(index.count(.account("History")) == 1)
}

// MARK: - The merge still composes with the local folder

@Test func multiAccountMergeFeedsTheLocalFolderMerge() throws {
    let us = try fixture("library-page1"), es = try fixture("library-account-es", "es")
    let audible = AudibleLibrary.merge(accounts: [.init(id: "us", books: us), .init(id: "es", books: es)])
    var local = book("B0BXXXX101", title: "Local copy")
    local.files = [BookFile(path: "books/local.m4b", type: .m4b)]
    let merged = AudibleLibrary.merge(audible: audible, local: [local])

    let owned = merged.first { $0.asin == "B0BXXXX101" }
    #expect(owned?.hasAudio == true, "the folder supplies the file")
    #expect(owned?.accountIDs == ["es"], "and the owner survives the second merge")
    #expect(owned?.title == "Solo en España", "Audible still supplies the metadata")
}

@Test func aFolderOnlyBookHasNoOwner() throws {
    let us = try fixture("library-page1"), es = try fixture("library-account-es", "es")
    let audible = AudibleLibrary.merge(accounts: [.init(id: "us", books: us), .init(id: "es", books: es)])
    var local = book("B0LOCAL001", title: "Only on disk")
    local.files = [BookFile(path: "books/only.m4b", type: .m4b)]
    var index = LibraryIndex()
    index.books = AudibleLibrary.merge(audible: audible, local: [local])

    let folderOnly = index.books.first { $0.asin == "B0LOCAL001" }
    #expect(folderOnly?.accountIDs == [], "no account owns a book that only the folder has")
    #expect(index.count(.all) == 5)
    #expect(index.count(.account("us")) == 2, "the counts are the Audible books' alone")
    #expect(index.count(.account("es")) == 4)
}

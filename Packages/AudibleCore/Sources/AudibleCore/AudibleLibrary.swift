import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The user's Audible library list (metadata only), fetched with signed `GET /1.0/library` calls.
public enum AudibleLibrary {
    /// OpenAudible's `library_groups` (spec §2.1).
    public static let responseGroups = "product_attrs,contributors,customer_rights,relationships,media,product_desc,product_extended_attrs,product_plans,pdf_url,series,category_ladders,rating,sku,listening_status,percent_complete,is_finished"

    public typealias Send = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// `purchasedAfter` limits the list to books bought since then, sent in UTC with microseconds
    /// ("2026-10-01T00:00:00.000000Z"), the format audible-cli sends (`strftime("%Y-%m-%dT%H:%M:%S.%fZ")`).
    public static func request(page: Int, pageSize: Int, marketplace: Marketplace, purchasedAfter: Date? = nil) -> URLRequest {
        var c = URLComponents(url: marketplace.audibleAPI.appendingPathComponent("1.0/library"), resolvingAgainstBaseURL: false)!
        c.queryItems = [
            URLQueryItem(name: "response_groups", value: responseGroups),
            URLQueryItem(name: "num_results", value: String(pageSize)),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "sort_by", value: "PurchaseDate"),
        ]
        if let purchasedAfter {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS'Z'"
            c.queryItems?.append(URLQueryItem(name: "purchased_after", value: f.string(from: purchasedAfter)))
        }
        return URLRequest(url: c.url!)
    }

    /// Fetches every page until a short one. Each page is tried up to 3 times with doubling delays.
    public static func fetch(account: AudibleAccount, pageSize: Int = 100, retryDelay: Duration = .seconds(1), purchasedAfter: Date? = nil,
                             send: Send, progress: @Sendable (Int) -> Void = { _ in }) async throws -> [Book] {
        var books: [Book] = []
        // Pages shift if a purchase lands mid-sync; keep each ASIN's first occurrence.
        var seen = Set<String>()
        for page in 1... {
            var request = request(page: page, pageSize: pageSize, marketplace: account.marketplace, purchasedAfter: purchasedAfter)
            try account.sign(&request)
            let items: [Item] = try await withRetry(delay: retryDelay) { try await parseItems(send(request)) }
            books += items.compactMap { seen.insert($0.asin).inserted ? book(from: $0, marketplace: account.marketplace) : nil }
            progress(books.count)
            if items.count < pageSize { break }
        }
        return books
    }

    static func withRetry<T>(attempts: Int = 3, delay: Duration, _ body: () async throws -> T) async throws -> T {
        var wait = delay
        for _ in 1..<attempts {
            do { return try await body() } catch is CancellationError { throw CancellationError() } catch {}
            try await Task.sleep(for: wait)
            wait *= 2
        }
        return try await body()
    }

    static func parseItems(_ response: (Data, URLResponse)) throws -> [Item] {
        let (data, urlResponse) = response
        if let http = urlResponse as? HTTPURLResponse, http.statusCode != 200 {
            throw AudibleError("Audible returned HTTP \(http.statusCode) for the library.")
        }
        do { return try JSONDecoder().decode(Page.self, from: data).items }
        catch { throw AudibleError("Unexpected library response from Audible.") }
    }

    struct Page: Decodable { var items: [Item] }

    struct Item: Decodable {
        struct Person: Decodable { var name: String }
        struct Ladder: Decodable { struct Rung: Decodable { var name: String }; var ladder: [Rung] }
        struct Rating: Decodable {
            struct Distribution: Decodable { var average_rating: Double?; var num_ratings: Int? }
            var overall_distribution: Distribution?
        }
        var asin: String
        var title: String?
        var authors: [Person]?
        var narrators: [Person]?
        var publisher_name: String?
        var publisher_summary: String?
        var merchandising_summary: String?
        var runtime_length_min: Int?
        var release_date: String?
        var purchase_date: String?
        var category_ladders: [Ladder]?
        var rating: Rating?
        var product_images: [String: String]?
        var is_finished: Bool?
        var percent_complete: Double?
        struct Plan: Decodable { var plan_name: String? }
        var is_ayce: Bool?
        var plans: [Plan]?
        var pdf_url: String?

        /// Added with Audible Plus and no Plus or free plan covers it now, so Audible denies its license.
        /// Libation's rule (`LibraryBookImporter.isPlusTitleUnavailable`, plan names from AudibleApi's `Plan.IsAyce`).
        var unavailable: Bool {
            is_ayce == true && !(plans ?? []).contains { plan in
                ["Minerva", "AYCL", "Free"].contains { plan.plan_name?.localizedCaseInsensitiveContains($0) == true }
            }
        }
    }

    static func book(from item: Item, marketplace: Marketplace) -> Book {
        let rating = item.rating?.overall_distribution
        func names(_ people: [Item.Person]?) -> String { (people ?? []).map(\.name).joined(separator: ", ") }
        // Only the calendar day matters, as in books.json.
        func day(_ s: String?) -> Date? { s.flatMap { Book.day.date(from: String($0.prefix(10))) } }
        var book = Book(
            asin: item.asin, key: item.asin,
            title: HTMLText.markdown(item.title ?? ""),
            author: names(item.authors), narratedBy: names(item.narrators),
            publisher: item.publisher_name ?? "",
            genre: (item.category_ladders?.first?.ladder ?? []).map(\.name).joined(separator: ":"),
            summary: item.publisher_summary ?? item.merchandising_summary ?? "",
            seconds: (item.runtime_length_min ?? 0) * 60,
            rating: rating?.average_rating, ratingCount: rating?.num_ratings,
            releaseDate: day(item.release_date), purchaseDate: day(item.purchase_date),
            region: marketplace.code.uppercased(),
            readStatus: item.is_finished == true ? .finished : (item.percent_complete ?? 0) > 0 ? .reading : nil,
            imageURL: item.product_images?["500"].flatMap(URL.init(string:)),
            chapters: [], files: [])
        book.unavailable = item.unavailable
        book.hasCompanionPDF = item.pdf_url?.isEmpty == false
        return book
    }

    /// The signed request for a book's companion PDF. Like audible-cli's `get_pdf_url`, it ignores the
    /// value of `pdf_url` and asks `www.audible.<domain>/companion-file/<asin>`, which redirects to the file.
    public static func companionPDFRequest(asin: String, account: AudibleAccount) throws -> URLRequest {
        guard AudibleContent.validASIN(asin) else { throw AudibleError("Invalid Audible book identifier.") }
        var request = URLRequest(url: URL(string: "https://www.audible.\(account.marketplace.domain)/companion-file/\(asin)")!)
        try account.sign(&request)
        // `sign` asks for JSON; the signature doesn't cover Accept.
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        return request
    }

    /// True when `data` starts like a PDF, not an HTML or JSON error page.
    public static func isPDF(_ data: Data) -> Bool { data.starts(with: Data("%PDF".utf8)) }

    /// One signed-in account's synced catalog.
    public struct AccountCatalog: Sendable {
        public let id: String
        public let books: [Book]

        public init(id: String, books: [Book]) {
            self.id = id
            self.books = books
        }
    }

    /// Folds a partial (`purchasedAfter`) fetch into the saved catalog by ASIN: fetched books replace
    /// their saved entry in place, new ones are appended, and every other saved book is kept as is.
    public static func merge(saved: [Book], fetched: [Book]) -> [Book] {
        let byASIN = Dictionary(fetched.map { ($0.asin, $0) }, uniquingKeysWith: { a, _ in a })
        let savedASINs = Set(saved.map(\.asin))
        return saved.map { byASIN[$0.asin] ?? $0 } + fetched.filter { !savedASINs.contains($0.asin) }
    }

    /// Merges the catalogs of several accounts into one list, by ASIN.
    ///
    /// The first account that owns a book supplies its metadata, so `accounts` order (sign-in order)
    /// decides ties. Owners accumulate in `Book.accountIDs`, and a book counts as finished if any
    /// account finished it, or as being listened to if any account is listening. Books only a later
    /// account owns are appended in that account's own order, so the result is stable across syncs.
    /// The result still goes through `merge(audible:local:)` to pick up local files (issue #47).
    public static func merge(accounts: [AccountCatalog]) -> [Book] {
        var merged: [Book] = []
        var index: [Book.ID: Int] = [:]
        for account in accounts {
            for book in account.books {
                guard let found = index[book.id] else {
                    var first = book
                    first.accountIDs = [account.id]
                    index[book.id] = merged.count
                    merged.append(first)
                    continue
                }
                if !merged[found].accountIDs.contains(account.id) { merged[found].accountIDs.append(account.id) }
                merged[found].readStatus = furthest(merged[found].readStatus, book.readStatus)
            }
        }
        return merged
    }

    /// The further along of two accounts' read status for the same book.
    static func furthest(_ a: ReadStatus?, _ b: ReadStatus?) -> ReadStatus? {
        if a == .finished || b == .finished { return .finished }
        if a == .reading || b == .reading { return .reading }
        return a ?? b
    }

    /// Audible gives the list and metadata; the OpenAudible folder gives files, chapters and read status.
    /// Files are the local ones plus any `audible`-side file of another type (OpenAudible's PDF, art, AAX beside a download).
    /// Books only in the folder (not on this account) are kept after the Audible ones.
    public static func merge(audible: [Book], local: [Book]) -> [Book] {
        guard !audible.isEmpty else { return local }
        let byASIN = Dictionary(local.filter { !$0.asin.isEmpty }.map { ($0.asin, $0) }, uniquingKeysWith: { a, _ in a })
        var merged = audible.map { a in
            guard let l = byASIN[a.asin] else { return a }
            var b = a
            b.key = l.key
            let localTypes = Set(l.files.map(\.type))
            b.files = l.files + a.files.filter { !localTypes.contains($0.type) && !(l.hasAudio && [.m4b, .mp3].contains($0.type)) }
            b.chapters = l.chapters
            b.readStatus = a.readStatus ?? l.readStatus
            if b.summary.isEmpty { b.summary = l.summary }
            if b.genre.isEmpty { b.genre = l.genre }
            return b
        }
        let onAudible = Set(audible.map(\.asin))
        merged += local.filter { $0.asin.isEmpty || !onAudible.contains($0.asin) }
        return merged
    }

    /// Lectern Audio's own copy of the list, in books.json format.
    public static func load(from url: URL) -> [Book] {
        (try? JSONDecoder().decode([Book].self, from: Data(contentsOf: url))) ?? []
    }

    public static func save(_ books: [Book], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(books).write(to: url, options: .atomic)
    }
}

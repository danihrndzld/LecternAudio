import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The user's Audible library list (metadata only), fetched with signed `GET /1.0/library` calls.
public enum AudibleLibrary {
    /// OpenAudible's `library_groups` (spec §2.1).
    public static let responseGroups = "product_attrs,contributors,customer_rights,relationships,media,product_desc,product_extended_attrs,pdf_url,series,category_ladders,rating,sku,listening_status,percent_complete,is_finished"

    public typealias Send = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public static func request(page: Int, pageSize: Int, marketplace: Marketplace) -> URLRequest {
        var c = URLComponents(url: marketplace.audibleAPI.appendingPathComponent("1.0/library"), resolvingAgainstBaseURL: false)!
        c.queryItems = [
            URLQueryItem(name: "response_groups", value: responseGroups),
            URLQueryItem(name: "num_results", value: String(pageSize)),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "sort_by", value: "PurchaseDate"),
        ]
        return URLRequest(url: c.url!)
    }

    /// Fetches every page until a short one. Each page is tried up to 3 times with doubling delays.
    public static func fetch(account: AudibleAccount, pageSize: Int = 100, retryDelay: Duration = .seconds(1),
                             send: Send, progress: @Sendable (Int) -> Void = { _ in }) async throws -> [Book] {
        var books: [Book] = []
        // Pages shift if a purchase lands mid-sync; keep each ASIN's first occurrence.
        var seen = Set<String>()
        for page in 1... {
            var request = request(page: page, pageSize: pageSize, marketplace: account.marketplace)
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
    }

    static func book(from item: Item, marketplace: Marketplace) -> Book {
        let rating = item.rating?.overall_distribution
        func names(_ people: [Item.Person]?) -> String { (people ?? []).map(\.name).joined(separator: ", ") }
        // Only the calendar day matters, as in books.json.
        func day(_ s: String?) -> Date? { s.flatMap { Book.day.date(from: String($0.prefix(10))) } }
        return Book(
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

    /// Earmark's own copy of the list, in books.json format.
    public static func load(from url: URL) -> [Book] {
        (try? JSONDecoder().decode([Book].self, from: Data(contentsOf: url))) ?? []
    }

    public static func save(_ books: [Book], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(books).write(to: url, options: .atomic)
    }
}

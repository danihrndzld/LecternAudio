import Foundation

/// The library table's sortable columns, shared by the table headers and View ▸ Sort By.
public enum BookColumn: String, CaseIterable, Codable, Hashable, Sendable {
    case title, author, narrator, length, purchased, released, rating, genre

    public var title: String {
        switch self {
        case .title: "Title"
        case .author: "Author"
        case .narrator: "Narrator"
        case .length: "Length"
        case .purchased: "Purchased"
        case .released: "Released"
        case .rating: "Rating"
        case .genre: "Genre"
        }
    }
}

public struct BookComparator: SortComparator, Hashable, Sendable {
    public var column: BookColumn
    public var order: SortOrder

    public init(_ column: BookColumn, order: SortOrder = .forward) {
        self.column = column
        self.order = order
    }

    /// Newest purchases first, as the table opens.
    public static let defaultOrder = [BookComparator(.purchased, order: .reverse)]

    public func compare(_ a: Book, _ b: Book) -> ComparisonResult {
        let result: ComparisonResult = switch column {
        case .title: a.title.localizedStandardCompare(b.title)
        case .author: a.author.localizedStandardCompare(b.author)
        case .narrator: a.narratedBy.localizedStandardCompare(b.narratedBy)
        case .genre: a.primaryGenre.localizedStandardCompare(b.primaryGenre)
        case .length: Self.compare(a.seconds, b.seconds)
        case .purchased: Self.compare(a.purchaseDate ?? .distantPast, b.purchaseDate ?? .distantPast)
        case .released: Self.compare(a.releaseDate ?? .distantPast, b.releaseDate ?? .distantPast)
        case .rating: Self.compare(a.rating ?? 0, b.rating ?? 0)
        }
        guard order == .reverse else { return result }
        return switch result {
        case .orderedAscending: .orderedDescending
        case .orderedDescending: .orderedAscending
        case .orderedSame: .orderedSame
        }
    }

    private static func compare<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
        a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame
    }
}

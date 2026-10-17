public enum RandomBook {
    /// A random id from `ids`, never one in `current` when another exists; nil when `ids` is empty.
    public static func pick(from ids: [Book.ID], avoiding current: Set<Book.ID>, using rng: inout some RandomNumberGenerator) -> Book.ID? {
        let others = ids.filter { !current.contains($0) }
        return (others.isEmpty ? ids : others).randomElement(using: &rng)
    }
}

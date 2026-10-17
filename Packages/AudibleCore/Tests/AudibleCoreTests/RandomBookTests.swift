import Testing
@testable import AudibleCore

private struct Seeded: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

@Test func randomBookNeverRepeatsSelectionAndStaysInList() {
    var rng = Seeded(state: 42)
    let ids = ["a", "b", "c"]
    var seen: Set<String> = []
    for _ in 0..<200 {
        let id = RandomBook.pick(from: ids, avoiding: ["b"], using: &rng)
        #expect(id != "b")
        seen.insert(id!)
    }
    #expect(seen == ["a", "c"])
}

@Test func randomBookEdgeCases() {
    var rng = Seeded(state: 1)
    #expect(RandomBook.pick(from: [], avoiding: [], using: &rng) == nil)
    #expect(RandomBook.pick(from: ["a"], avoiding: ["a"], using: &rng) == "a")
}

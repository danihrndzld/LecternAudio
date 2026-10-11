import Foundation

/// Seek targets for the Player menu's chapter commands. Times are seconds from the book's start.
public enum ChapterNavigation {
    /// Seconds into a chapter after which "Previous Chapter" restarts the current one instead of going back.
    public static let restartGrace: TimeInterval = 3

    /// Index of the chapter playing at `time` (the last one starting at or before it).
    public static func index(at time: TimeInterval, in chapters: [Chapter]) -> Int? {
        chapters.lastIndex { $0.start <= time }
    }

    public static func previous(from time: TimeInterval, in chapters: [Chapter]) -> TimeInterval? {
        guard let i = index(at: time, in: chapters) else { return chapters.isEmpty ? nil : 0 }
        if time - chapters[i].start > restartGrace || i == 0 { return chapters[i].start }
        return chapters[i - 1].start
    }

    public static func next(from time: TimeInterval, in chapters: [Chapter]) -> TimeInterval? {
        chapters.first { $0.start > time }?.start
    }

    /// Start and end of the chapter at `time`; the end is the next chapter's start, else start + length, capped at `duration`.
    public static func bounds(at time: TimeInterval, in chapters: [Chapter], duration: TimeInterval) -> ClosedRange<TimeInterval>? {
        guard let i = index(at: time, in: chapters) else { return nil }
        let start = chapters[i].start
        let end = i + 1 < chapters.count ? chapters[i + 1].start : start + Double(chapters[i].lengthMs) / 1000
        return start...max(start, min(end, duration > 0 ? duration : end))
    }
}

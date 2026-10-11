import Foundation

public enum AutoSync {
    /// Seconds to wait before the next automatic library sync, or nil when `hours` is 0 (off).
    /// `last` is the last sync or attempt; nil waits a full interval. Never under a minute, never over the interval.
    public static func delay(hours: Int, last: Date?, now: Date = .now) -> TimeInterval? {
        guard hours > 0 else { return nil }
        let interval = TimeInterval(hours) * 3600
        guard let last else { return interval }
        return min(interval, max(60, last.addingTimeInterval(interval).timeIntervalSince(now)))
    }
}

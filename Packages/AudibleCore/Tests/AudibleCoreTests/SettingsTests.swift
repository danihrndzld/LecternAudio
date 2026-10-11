import Foundation
import Testing
@testable import AudibleCore

@Test func autoSyncDelay() {
    let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
    #expect(AutoSync.delay(hours: 0, last: now, now: now) == nil)
    #expect(AutoSync.delay(hours: 24, last: nil, now: now) == 86_400)
    #expect(AutoSync.delay(hours: 24, last: now.addingTimeInterval(-3_600), now: now) == 82_800)
    // Overdue syncs wait a minute instead of looping; a clock set back never waits longer than one interval.
    #expect(AutoSync.delay(hours: 1, last: now.addingTimeInterval(-90_000), now: now) == 60)
    #expect(AutoSync.delay(hours: 1, last: now.addingTimeInterval(90_000), now: now) == 3_600)
}

@Test func everyOfferedBitrateIsValidForLAME() throws {
    #expect(MP3Encoder.bitrates.first == 32 && MP3Encoder.bitrates.last == 320 && MP3Encoder.bitrates.contains(64))
    for bitrate in MP3Encoder.bitrates {
        for mode in [MP3Encoder.Mode.cbr, .vbr] {
            _ = try MP3Encoder(sampleRate: 44_100, channels: bitrate <= 64 ? 1 : 2, bitrate: bitrate, mode: mode)
        }
    }
}

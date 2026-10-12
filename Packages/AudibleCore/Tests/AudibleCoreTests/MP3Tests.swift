import Foundation
import Testing
@testable import AudibleCore

@Test func synchsafeIntegers() {
    #expect(ID3Tag.synchsafe(0) == Data([0, 0, 0, 0]))
    #expect(ID3Tag.synchsafe(127) == Data([0, 0, 0, 0x7F]))
    #expect(ID3Tag.synchsafe(128) == Data([0, 0, 1, 0]))
    #expect(ID3Tag.synchsafe(0x0FFF_FFFF) == Data([0x7F, 0x7F, 0x7F, 0x7F]))
}

@Test func id3HeaderAndTextFrame() {
    var tag = ID3Tag()
    tag.title = "Ñu"
    let d = tag.data
    // "ID3" v2.4.0, no flags, size = one frame of 10 + 1 + 3 bytes
    #expect(Array(d.prefix(10)) == [0x49, 0x44, 0x33, 4, 0, 0, 0, 0, 0, 14])
    #expect(Array(d.dropFirst(10)) == Array("TIT2".utf8) + [0, 0, 0, 4, 0, 0, 3] + Array("Ñu".utf8))
}

@Test func id3FrameSizesAddUp() {
    var tag = ID3Tag()
    tag.title = "Book"; tag.artist = "Author"; tag.composer = "Narrator"; tag.comment = "Summary"
    tag.cover = Data([0xFF, 0xD8, 0xFF, 0xE0] + Array(repeating: 0, count: 300))  // > 127 bytes exercises synchsafe
    let d = tag.data
    var i = 10, ids: [String] = []
    while i < d.count {
        ids.append(String(decoding: d[i..<i + 4], as: UTF8.self))
        let size = d[i + 4..<i + 8].reduce(0) { $0 << 7 | Int($1) }
        i += 10 + size
    }
    #expect(i == d.count)
    #expect(ids == ["TIT2", "TPE1", "TCOM", "COMM", "APIC"])
    let apic = d.range(of: Data("APIC".utf8))!.upperBound
    #expect(Array(d[apic..<apic + 4]) == [0, 0, 2, 62])  // 1 + 10 ("image/jpeg") + 1 + 1 + 1 + 304 = 318 = 2·128 + 62
    #expect(d[(apic + 6)...].starts(with: [0] + Array("image/jpeg".utf8) + [0, 3, 0, 0xFF, 0xD8]))
}

@Test func chapterFrameLayout() {
    var tag = ID3Tag()
    tag.chapters = [Chapter(title: "One", startMs: 0, lengthMs: 1500), Chapter(title: "Two", startMs: 1500, lengthMs: 70_000)]
    let d = Array(tag.data.dropFirst(10))
    func b(_ s: String) -> [UInt8] { Array(s.utf8) }
    let ctoc: [UInt8] = [b("CTOC"), [0, 0, 0, 14, 0, 0], b("toc\0"), [0x03, 2], b("ch0\0"), b("ch1\0")].flatMap { $0 }
    #expect(Array(d.prefix(ctoc.count)) == ctoc)
    let tit2: [UInt8] = [b("TIT2"), [0, 0, 0, 4, 0, 0, 3], b("Two")].flatMap { $0 }
    let times: [UInt8] = [0, 0, 0x05, 0xDC, 0, 0x01, 0x17, 0x4C]  // 1500 ms, 71500 ms
    let chap: [UInt8] = [b("CHAP"), [0, 0, 0, 34, 0, 0], b("ch1\0"), times, [UInt8](repeating: 0xFF, count: 8), tit2].flatMap { $0 }
    #expect(Array(d.suffix(chap.count)) == chap)
}

@Test func lameEncodesSine() throws {
    let rate = 44_100
    let pcm = (0..<rate).map { Int16(sin(Double($0) * 2 * .pi * 440 / Double(rate)) * 12_000) }
    let enc = try MP3Encoder(sampleRate: rate, channels: 1)
    var mp3 = try pcm.withUnsafeBufferPointer { try enc.encode($0) }
    mp3 += try enc.flush()
    let tag = enc.lameTag
    #expect(!tag.isEmpty)
    mp3.replaceSubrange(0..<tag.count, with: tag)
    // MPEG-1 Layer III frame sync; 64 kbps (index 5), 44.1 kHz (index 0), mono (mode 3)
    #expect(mp3[0] == 0xFF && mp3[1] & 0xFE == 0xFA)
    #expect(mp3[2] >> 4 == 5 && (mp3[2] >> 2) & 3 == 0)
    #expect(mp3[3] >> 6 == 3)
    #expect(Data(mp3[21..<25]) == Data("Info".utf8))  // CBR Info tag after 4-byte header + 17-byte mono side info
    #expect(mp3.count > 7_000 && mp3.count < 10_000)  // ≈ 64 kbit/s × 1 s
}

#if canImport(AVFoundation)
import AVFoundation

@Test func exportsM4AToMP3() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let m4a = dir.appendingPathComponent("in.m4a")
    let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
    do {
        let file = try AVAudioFile(forWriting: m4a, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2])
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100 * 3)!
        buf.frameLength = buf.frameCapacity
        for ch in 0..<2 {
            for i in 0..<Int(buf.frameLength) { buf.floatChannelData![ch][i] = Float(sin(Double(i) * 2 * .pi * 330 / 44_100) * 0.3) }
        }
        try file.write(from: buf)
    }
    let source = try await AVURLAsset(url: m4a).load(.duration).seconds

    var tag = ID3Tag()
    tag.title = "Test"
    let mp3 = dir.appendingPathComponent("out.mp3")
    try await MP3Export.run(source: m4a, destination: mp3, tag: tag)
    // Default options: 320 kbps CBR stereo. First frame after the ID3 tag: bitrate index 14, channel mode not mono.
    #expect(MP3Export.Options().bitrate == 320 && MP3Export.Options().mode == .cbr)
    let bytes = [UInt8](try Data(contentsOf: mp3))
    let frame = 10 + bytes[6..<10].reduce(0) { $0 << 7 | Int($1) }
    #expect(bytes[frame] == 0xFF && bytes[frame + 2] >> 4 == 14 && bytes[frame + 3] >> 6 != 3)
    let out = try await AVURLAsset(url: mp3).load(.duration).seconds
    #expect(abs(out - source) < 0.1, "source \(source) s, mp3 \(out) s")

    tag.chapters = [Chapter(title: "A", startMs: 0, lengthMs: 1000), Chapter(title: "B/C", startMs: 1000, lengthMs: 2000)]
    var options = MP3Export.Options()
    options.splitChapters = true
    let folder = dir.appendingPathComponent("split")
    try await MP3Export.run(source: m4a, destination: folder, tag: tag, options: options)
    let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    #expect(names == ["01 - A.mp3", "02 - B-C.mp3"])
    let second = try await AVURLAsset(url: folder.appendingPathComponent(names[1])).load(.duration).seconds
    #expect(abs(second - 2) < 0.1, "chapter 2 is \(second) s")
}
#endif

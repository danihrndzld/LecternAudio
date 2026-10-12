import Foundation
import Testing
@testable import AudibleCore

private func le32(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 | Int(b[i + 2]) << 16 | Int(b[i + 3]) << 24 }
private func be32(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3]) }

@Test func vorbisCommentFields() {
    var tag = ID3Tag()
    tag.title = "Book"; tag.artist = "Author"; tag.album = "Book"; tag.composer = "Narrator"
    tag.year = "2020"; tag.genre = "Fiction"; tag.comment = "Summary"
    tag.chapters = [Chapter(title: "Opening", startMs: 0, lengthMs: 61_500),
                    Chapter(title: "Two", startMs: 3_723_004, lengthMs: 1000)]
    #expect(VorbisComment.fields(tag) == [
        "TITLE=Book", "ARTIST=Author", "ALBUM=Book", "PERFORMER=Narrator", "COMPOSER=Narrator", "DATE=2020",
        "GENRE=Fiction", "DESCRIPTION=Summary", "COMMENT=Summary",
        "CHAPTER001=00:00:00.000", "CHAPTER001NAME=Opening", "CHAPTER002=01:02:03.004", "CHAPTER002NAME=Two",
    ])
}

@Test func vorbisCommentPacketLayout() {
    let p = [UInt8](VorbisComment.packet(vendor: "V", fields: ["A=1", "TITLE=Ñ"]))
    func b(_ s: String) -> [UInt8] { Array(s.utf8) }
    let expected: [UInt8] = [[3], b("vorbis"), [1, 0, 0, 0], b("V"), [2, 0, 0, 0],
                             [3, 0, 0, 0], b("A=1"), [8, 0, 0, 0], b("TITLE=Ñ"), [1]].flatMap { $0 }
    #expect(p == expected)
    #expect(VorbisComment.vendor(of: Data(p)) == "V")
}

@Test func metadataBlockPictureLayout() throws {
    var tag = ID3Tag()
    let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0] + Array(repeating: 7, count: 300))
    tag.cover = jpeg
    let field = try #require(VorbisComment.fields(tag).first)
    #expect(field.hasPrefix("METADATA_BLOCK_PICTURE="))
    let b = [UInt8](try #require(Data(base64Encoded: String(field.dropFirst("METADATA_BLOCK_PICTURE=".count)))))
    #expect(be32(b, 0) == 3)  // front cover
    #expect(be32(b, 4) == 10 && b[8..<18].elementsEqual("image/jpeg".utf8))
    #expect(be32(b, 18) == 0)  // empty description
    #expect(be32(b, 22) == 0 && be32(b, 26) == 0 && be32(b, 30) == 0 && be32(b, 34) == 0)  // width, height, depth, colors
    #expect(be32(b, 38) == jpeg.count && Data(b[42...]) == jpeg)
}

/// Splits an Ogg stream into pages: (header type flags, body bytes).
private func pages(_ d: [UInt8]) -> [(type: UInt8, body: [UInt8])] {
    var out: [(UInt8, [UInt8])] = [], i = 0
    while i + 27 <= d.count, d[i..<i + 4].elementsEqual("OggS".utf8) {
        let segments = Int(d[i + 26])
        let size = d[i + 27..<i + 27 + segments].reduce(0) { $0 + Int($1) }
        let start = i + 27 + segments
        out.append((d[i + 5], Array(d[start..<start + size])))
        i = start + size
    }
    #expect(i == d.count, "trailing bytes after the last page")
    return out
}

@Test func vorbisEncodesSine() throws {
    let rate = 44_100
    let pcm = (0..<rate).flatMap { i -> [Float] in
        let s = Float(sin(Double(i) * 2 * .pi * 440 / Double(rate)) * 0.4)
        return [s, s]
    }
    let enc = try VorbisEncoder(sampleRate: rate, channels: 2, comments: ["TITLE=Sine", "CHAPTER001=00:00:00.000"])
    var ogg = pcm.withUnsafeBufferPointer { enc.encode($0) }
    ogg += enc.finish()
    let d = [UInt8](ogg)
    #expect(d.starts(with: Array("OggS".utf8)))
    let ps = pages(d)
    #expect(ps.first?.type == 2 && (ps.last?.type ?? 0) & 4 == 4)  // beginning and end of stream
    // Page 0 holds only the identification header: 0x01 "vorbis", version 0, 2 channels, 44100 Hz, nominal about 500 kbps (q10).
    let ident = try #require(ps.first?.body)
    #expect(ident.count == 30 && ident[0] == 1 && ident[1..<7].elementsEqual("vorbis".utf8))
    #expect(le32(ident, 7) == 0 && ident[11] == 2 && le32(ident, 12) == rate && abs(le32(ident, 20) - 500_000) < 1_000)  // 499 821 bit/s
    // The comment header starts page 1 and carries our fields.
    let comment = ps[1].body
    #expect(comment[0] == 3 && comment[1..<7].elementsEqual("vorbis".utf8))
    let vendorLength = le32(comment, 7)
    #expect(String(decoding: comment[11..<11 + vendorLength], as: UTF8.self).hasPrefix("Xiph.Org libVorbis"))
    #expect(le32(comment, 11 + vendorLength) == 2)
    #expect(d.count > 4_000 && d.count < 100_000, "\(d.count) bytes for 1 s")
}

@Test func vorbisInitsAtCommonRates() throws {
    for rate in [8_000, 11_025, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000] {
        for channels in [1, 2] {
            for quality: Float in [0, 1] {
                _ = try VorbisEncoder(sampleRate: rate, channels: channels, quality: quality)
            }
        }
    }
}

#if canImport(AVFoundation)
import AVFoundation

@Test func exportsM4AToOgg() async throws {
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
    tag.chapters = [Chapter(title: "A", startMs: 0, lengthMs: 1000), Chapter(title: "B/C", startMs: 1000, lengthMs: 2000)]
    let ogg = dir.appendingPathComponent("out.ogg")
    try await OggExport.run(source: m4a, destination: ogg, tag: tag)
    let bytes = try Data(contentsOf: ogg)
    #expect(bytes.starts(with: Data("OggS".utf8)))
    #expect(bytes.range(of: Data("CHAPTER002NAME=B/C".utf8)) != nil)
    #expect(!FileManager.default.fileExists(atPath: ogg.path + ".part"))
    // macOS decodes Ogg Vorbis (Core Audio, macOS 14 and later).
    let out = try await AVURLAsset(url: ogg).load(.duration).seconds
    #expect(abs(out - source) < 0.1, "source \(source) s, ogg \(out) s")

    var options = OggExport.Options()
    options.splitChapters = true
    let folder = dir.appendingPathComponent("split")
    try await OggExport.run(source: m4a, destination: folder, tag: tag, options: options)
    let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    #expect(names == ["01 - A.ogg", "02 - B-C.ogg"])
    let second = try await AVURLAsset(url: folder.appendingPathComponent(names[1])).load(.duration).seconds
    #expect(abs(second - 2) < 0.1, "chapter 2 is \(second) s")
}
#endif

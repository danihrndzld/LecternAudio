import Foundation

/// ID3v2.4 tag (id3.org id3v2.4.0-structure/-frames) with ID3v2 Chapter Frame Addendum 1.0 CHAP/CTOC frames.
/// Text is UTF-8 (encoding byte 3).
public struct ID3Tag: Sendable, Equatable {
    public var title = ""
    public var artist = ""
    public var album = ""
    public var composer = ""
    public var year = ""
    public var genre = ""
    public var comment = ""
    public var track = ""
    public var cover: Data?
    public var chapters: [Chapter] = []

    public init() {}

    public var data: Data {
        var frames = Data()
        let texts = [("TIT2", title), ("TPE1", artist), ("TALB", album), ("TCOM", composer),
                     ("TDRC", year), ("TCON", genre), ("TRCK", track)]
        for (id, value) in texts where !value.isEmpty { frames += Self.text(id, value) }
        if !comment.isEmpty {
            frames += Self.frame("COMM", Data([3]) + Data("eng".utf8) + Data([0]) + Data(comment.utf8))
        }
        if let cover {
            let mime = cover.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "image/png" : "image/jpeg"
            // encoding 0, MIME, NUL, picture type 3 (front cover), empty description NUL, image bytes
            frames += Self.frame("APIC", Data([0]) + Data(mime.utf8) + Data([0, 3, 0]) + cover)
        }
        if !chapters.isEmpty {
            let ids = chapters.indices.map { Data("ch\($0)".utf8) + Data([0]) }
            // ponytail: CTOC's entry count is one byte, so it lists the first 255 chapters; nest CTOCs if a book ever needs more.
            let listed = ids.prefix(255)
            frames += Self.frame("CTOC", Data("toc".utf8) + Data([0, 0x03, UInt8(listed.count)]) + listed.reduce(Data(), +))
            for (id, c) in zip(ids, chapters) {
                // start ms, end ms, then start/end byte offsets unused (0xFFFFFFFF)
                let body = id + Self.uint32(c.startMs) + Self.uint32(c.startMs + c.lengthMs)
                    + Data(repeating: 0xFF, count: 8) + Self.text("TIT2", c.title)
                frames += Self.frame("CHAP", body)
            }
        }
        return Data("ID3".utf8) + Data([4, 0, 0]) + Self.synchsafe(frames.count) + frames
    }

    static func text(_ id: String, _ value: String) -> Data { frame(id, Data([3]) + Data(value.utf8)) }

    static func frame(_ id: String, _ body: Data) -> Data {
        Data(id.utf8) + synchsafe(body.count) + Data([0, 0]) + body
    }

    /// 28-bit big-endian integer stored as four 7-bit bytes.
    static func synchsafe(_ n: Int) -> Data {
        Data([21, 14, 7, 0].map { UInt8((n >> $0) & 0x7F) })
    }

    static func uint32(_ n: Int) -> Data {
        Data([24, 16, 8, 0].map { UInt8((n >> $0) & 0xFF) })
    }
}

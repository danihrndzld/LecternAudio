import COgg
import CVorbis
import Foundation

/// Thin wrapper over libvorbis + libogg. The first `encode` result starts with the three header pages; call `finish()` last.
public final class VorbisEncoder {
    public struct Failure: Error, CustomStringConvertible {
        public let code: Int32
        public var description: String { "libvorbis error \(code)" }
    }

    // libvorbis keeps pointers between these (vd->vi, vb->vd), so they need fixed heap addresses.
    private let vi: UnsafeMutablePointer<vorbis_info>
    private let vc: UnsafeMutablePointer<vorbis_comment>
    private let vd: UnsafeMutablePointer<vorbis_dsp_state>
    private let vb: UnsafeMutablePointer<vorbis_block>
    private let os: UnsafeMutablePointer<ogg_stream_state>
    private let channels: Int
    private var page = ogg_page()
    private var pending = Data()

    /// `quality` is libvorbis VBR quality, -0.1...1.0 (1.0 = q10). `comments` are `KEY=value` fields (see `VorbisComment`).
    public init(sampleRate: Int, channels: Int, quality: Float = 1.0, comments: [String] = []) throws {
        let vi = UnsafeMutablePointer<vorbis_info>.allocate(capacity: 1)
        vorbis_info_init(vi)
        let rc = vorbis_encode_init_vbr(vi, channels, sampleRate, quality)
        if rc != 0 {  // before self is complete, so deinit does not run
            vorbis_info_clear(vi)
            vi.deallocate()
            throw Failure(code: rc)
        }
        self.vi = vi
        (vc, vd, vb, os) = (.allocate(capacity: 1), .allocate(capacity: 1), .allocate(capacity: 1), .allocate(capacity: 1))
        self.channels = channels
        vorbis_comment_init(vc)
        vorbis_analysis_init(vd, vi)
        vorbis_block_init(vd, vb)
        ogg_stream_init(os, Int32.random(in: 1...Int32.max))

        var ident = ogg_packet(), comment = ogg_packet(), books = ogg_packet()
        vorbis_analysis_headerout(vd, vc, &ident, &comment, &books)
        let generated = Data(bytes: comment.packet, count: comment.bytes)
        var ours = VorbisComment.packet(vendor: VorbisComment.vendor(of: generated) ?? "", fields: comments)
        ogg_stream_packetin(os, &ident)
        ours.withUnsafeMutableBytes { buf in  // libogg copies the body
            comment.packet = buf.baseAddress!.assumingMemoryBound(to: UInt8.self)
            comment.bytes = buf.count
            ogg_stream_packetin(os, &comment)
        }
        ogg_stream_packetin(os, &books)
        while ogg_stream_flush(os, &page) != 0 { appendPage() }  // ident alone on page 0, audio starts on a fresh page
    }

    deinit {
        ogg_stream_clear(os)
        vorbis_block_clear(vb)
        vorbis_dsp_clear(vd)
        vorbis_comment_clear(vc)
        vorbis_info_clear(vi)
        vi.deallocate(); vc.deallocate(); vd.deallocate(); vb.deallocate(); os.deallocate()
    }

    /// `pcm` holds interleaved frames (`count / channels` samples per channel), -1...1.
    public func encode(_ pcm: UnsafeBufferPointer<Float>) -> Data {
        let frames = pcm.count / channels
        if frames > 0, let buffer = vorbis_analysis_buffer(vd, Int32(frames)) {
            for ch in 0..<channels {
                let out = buffer[ch]!
                for i in 0..<frames { out[i] = pcm[i * channels + ch] }
            }
            vorbis_analysis_wrote(vd, Int32(frames))
            drain()
        }
        return take()
    }

    /// Ends the stream and returns the last pages.
    public func finish() -> Data {
        vorbis_analysis_wrote(vd, 0)
        drain()
        while ogg_stream_flush(os, &page) != 0 { appendPage() }
        return take()
    }

    private func drain() {
        var packet = ogg_packet()
        while vorbis_analysis_blockout(vd, vb) == 1 {
            vorbis_analysis(vb, nil)
            vorbis_bitrate_addblock(vb)
            while vorbis_bitrate_flushpacket(vd, &packet) == 1 {
                ogg_stream_packetin(os, &packet)
                while ogg_stream_pageout(os, &page) != 0 { appendPage() }
            }
        }
    }

    private func appendPage() {
        pending.append(page.header, count: page.header_len)
        pending.append(page.body, count: page.body_len)
    }

    private func take() -> Data {
        defer { pending = Data() }
        return pending
    }
}

/// Vorbis comment header (Vorbis I spec §5) with the de facto tags players read:
/// METADATA_BLOCK_PICTURE (FLAC picture block, base64) for cover art and CHAPTERnnn/CHAPTERnnnNAME for chapters.
public enum VorbisComment {
    /// Fields for a book: `tag.composer` is the narrator (as in ID3), `tag.comment` the summary.
    public static func fields(_ tag: ID3Tag) -> [String] {
        let pairs = [("TITLE", tag.title), ("ARTIST", tag.artist), ("ALBUM", tag.album),
                     ("PERFORMER", tag.composer), ("COMPOSER", tag.composer), ("DATE", tag.year),
                     ("GENRE", tag.genre), ("TRACKNUMBER", tag.track),
                     ("DESCRIPTION", tag.comment), ("COMMENT", tag.comment)]
        var out = pairs.filter { !$0.1.isEmpty }.map { "\($0.0)=\($0.1)" }
        for (i, c) in tag.chapters.enumerated() {
            let n = String(format: "CHAPTER%03d", i + 1)
            out += ["\(n)=\(timestamp(c.startMs))", "\(n)NAME=\(c.title)"]
        }
        if let cover = tag.cover { out.append("METADATA_BLOCK_PICTURE=" + picture(cover).base64EncodedString()) }
        return out
    }

    /// `HH:MM:SS.mmm`
    static func timestamp(_ ms: Int) -> String {
        String(format: "%02d:%02d:%02d.%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
    }

    /// FLAC METADATA_BLOCK_PICTURE body (big-endian), front cover.
    // ponytail: width, height, depth and colors are 0 (unknown); ffmpeg and players accept that. Parse the image if one ever needs them.
    static func picture(_ image: Data) -> Data {
        let mime = image.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "image/png" : "image/jpeg"
        var d = be32(3) + be32(mime.utf8.count) + Data(mime.utf8) + be32(0)
        d += be32(0) + be32(0) + be32(0) + be32(0) + be32(image.count) + image
        return d
    }

    /// Packet type 3, "vorbis", vendor, fields, framing bit. Lengths are little-endian.
    static func packet(vendor: String, fields: [String]) -> Data {
        var d = Data([3]) + Data("vorbis".utf8) + le32(vendor.utf8.count) + Data(vendor.utf8) + le32(fields.count)
        for f in fields { d += le32(f.utf8.count) + Data(f.utf8) }
        return d + Data([1])
    }

    static func vendor(of packet: Data) -> String? {
        let p = [UInt8](packet)
        guard p.count >= 11 else { return nil }
        let n = Int(p[7]) | Int(p[8]) << 8 | Int(p[9]) << 16 | Int(p[10]) << 24
        guard p.count >= 11 + n else { return nil }
        return String(decoding: p[11..<11 + n], as: UTF8.self)
    }

    private static func be32(_ n: Int) -> Data { Data([24, 16, 8, 0].map { UInt8((n >> $0) & 0xFF) }) }
    private static func le32(_ n: Int) -> Data { Data([0, 8, 16, 24].map { UInt8((n >> $0) & 0xFF) }) }
}

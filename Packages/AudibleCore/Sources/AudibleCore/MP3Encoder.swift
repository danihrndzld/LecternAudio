import CLAME
import Foundation

/// Thin wrapper over LAME. Feed 16-bit interleaved PCM, then `flush()`, then write `lameTag` over the first MP3 frame.
public final class MP3Encoder {
    public enum Mode: Sendable { case cbr, vbr }

    /// MPEG-1/2 Layer III bitrates (kbps) LAME accepts, 32k…320k.
    public static let bitrates = [32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]

    public struct Failure: Error, CustomStringConvertible {
        public let code: Int32
        public var description: String { "LAME error \(code)" }
    }

    private let lame: OpaquePointer
    private let channels: Int

    /// `vbr` is LAME's ABR mode: frame sizes vary around `bitrate` kbps.
    public init(sampleRate: Int, channels: Int, bitrate: Int = 64, mode: Mode = .cbr) throws {
        guard let lame = lame_init() else { throw Failure(code: -1) }
        self.lame = lame
        self.channels = channels
        lame_set_in_samplerate(lame, Int32(sampleRate))
        lame_set_num_channels(lame, Int32(channels))
        switch mode {
        case .cbr: lame_set_brate(lame, Int32(bitrate))
        case .vbr:
            lame_set_VBR(lame, vbr_abr)
            lame_set_VBR_mean_bitrate_kbps(lame, Int32(bitrate))
        }
        let rc = lame_init_params(lame)
        if rc < 0 { lame_close(lame); throw Failure(code: rc) }
    }

    deinit { lame_close(lame) }

    /// `pcm` holds interleaved frames (`count / channels` samples per channel).
    public func encode(_ pcm: UnsafeBufferPointer<Int16>) throws -> Data {
        let frames = pcm.count / channels
        guard frames > 0, let base = pcm.baseAddress else { return Data() }
        var out = [UInt8](repeating: 0, count: frames * 5 / 4 + 7200)  // worst case from lame.h
        let n = channels == 1
            ? lame_encode_buffer(lame, base, base, Int32(frames), &out, Int32(out.count))
            : lame_encode_buffer_interleaved(lame, UnsafeMutablePointer(mutating: base), Int32(frames), &out, Int32(out.count))
        if n < 0 { throw Failure(code: n) }
        return Data(out.prefix(Int(n)))
    }

    public func flush() throws -> Data {
        var out = [UInt8](repeating: 0, count: 7200)
        let n = lame_encode_flush(lame, &out, Int32(out.count))
        if n < 0 { throw Failure(code: n) }
        return Data(out.prefix(Int(n)))
    }

    /// Xing/Info frame (duration, encoder delay) that replaces the placeholder first frame once encoding is done.
    public var lameTag: Data {
        var out = [UInt8](repeating: 0, count: 2880)
        let n = lame_get_lametag_frame(lame, &out, out.count)
        return Data(out.prefix(n <= out.count ? n : 0))
    }
}

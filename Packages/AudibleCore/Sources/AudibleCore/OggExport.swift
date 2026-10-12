#if canImport(AVFoundation)
import AVFoundation

/// Converts a plain (decrypted) M4B/M4A to Ogg Vorbis at the source's sample rate and channel count,
/// with metadata, cover and chapters as Vorbis comments.
public enum OggExport {
    public struct Options: Sendable {
        /// libvorbis VBR quality 0...10 (10 = maximum, about 500 kbps for 44.1 kHz stereo).
        public var quality = 10
        /// Write `destination/<nn> - <chapter>.ogg` instead of one file.
        public var splitChapters = false
        public init() {}
    }

    /// `tag.chapters` defaults to the source's chapters when empty. `progress` gets 0...1.
    public static func run(source: URL, destination: URL, tag: ID3Tag, options: Options = .init(),
                           progress: @Sendable (Double) -> Void = { _ in }) async throws {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw MP3Export.Failure(errorDescription: "\(source.lastPathComponent) has no audio track")
        }
        let duration = try await asset.load(.duration).seconds
        let format = try await track.load(.formatDescriptions).first
            .flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
        let sampleRate = Int(format?.mSampleRate ?? 44_100)
        let channels = max(1, Int(format?.mChannelsPerFrame ?? 2))
        var tag = tag
        if tag.chapters.isEmpty { tag.chapters = try await MP3Export.chapters(of: asset) }

        func encode(_ range: CMTimeRange?, _ tag: ID3Tag, to url: URL, overall: (Double) -> Double) throws {
            let reader = try AVAssetReader(asset: asset)
            if let range { reader.timeRange = range }
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
                AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels,
            ])
            reader.add(output)
            guard reader.startReading() else {
                throw reader.error ?? MP3Export.Failure(errorDescription: "Cannot read \(source.lastPathComponent)")
            }
            defer { reader.cancelReading() }

            let encoder = try VorbisEncoder(sampleRate: sampleRate, channels: channels,
                                            quality: Float(options.quality) / 10, comments: VorbisComment.fields(tag))
            try MP3Export.write(url) { file in
                let start = range?.start.seconds ?? 0, length = range?.duration.seconds ?? duration
                var reported = -1.0
                while let buffer = output.copyNextSampleBuffer() {
                    try Task.checkCancellation()
                    guard let pcm = try buffer.dataBuffer?.dataBytes() else { continue }
                    try file.write(contentsOf: pcm.withUnsafeBytes { encoder.encode($0.bindMemory(to: Float.self)) })
                    let done = (buffer.presentationTimeStamp.seconds - start) / max(length, 1)
                    if done - reported >= 0.005 { reported = done; progress(overall(min(max(done, 0), 1))) }
                }
                if reader.status != .completed { throw reader.error ?? MP3Export.Failure(errorDescription: "Decoding stopped early") }
                try file.write(contentsOf: encoder.finish())
            }
        }

        try MP3Export.perFile(tag: tag, destination: destination, ext: "ogg", duration: duration,
                              splitChapters: options.splitChapters, encode: encode)
    }
}
#endif

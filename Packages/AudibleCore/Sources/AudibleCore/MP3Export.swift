#if canImport(AVFoundation)
import AVFoundation

/// Converts a plain (decrypted) M4B/M4A to MP3: AVFoundation decodes, LAME encodes, `ID3Tag` tags.
public enum MP3Export {
    public struct Options: Sendable {
        public var bitrate = 64
        public var mode = MP3Encoder.Mode.cbr
        /// Write `destination/<nn> - <chapter>.mp3` instead of one file.
        public var splitChapters = false
        public init() {}
    }

    public struct Failure: LocalizedError {
        public let errorDescription: String?
    }

    /// `tag.chapters` defaults to the source's chapters when empty. `progress` gets 0...1.
    public static func run(source: URL, destination: URL, tag: ID3Tag, options: Options = .init(),
                           progress: @Sendable (Double) -> Void = { _ in }) async throws {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw Failure(errorDescription: "\(source.lastPathComponent) has no audio track")
        }
        let duration = try await asset.load(.duration).seconds
        let format = try await track.load(.formatDescriptions).first
            .flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
        let sampleRate = Int(format?.mSampleRate ?? 44_100)
        let channels = options.bitrate <= 64 ? 1 : min(Int(format?.mChannelsPerFrame ?? 2), 2)
        var tag = tag
        if tag.chapters.isEmpty { tag.chapters = try await chapters(of: asset) }

        func encode(_ range: CMTimeRange?, _ tag: ID3Tag, to url: URL, progress: (Double) -> Void) throws {
            let reader = try AVAssetReader(asset: asset)
            if let range { reader.timeRange = range }
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
                AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels,
            ])
            reader.add(output)
            guard reader.startReading() else { throw reader.error ?? Failure(errorDescription: "Cannot read \(source.lastPathComponent)") }
            defer { reader.cancelReading() }

            let encoder = try MP3Encoder(sampleRate: sampleRate, channels: channels, bitrate: options.bitrate, mode: options.mode)
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw Failure(errorDescription: "Cannot create \(url.path)")
            }
            do {
                let file = try FileHandle(forWritingTo: url)
                defer { try? file.close() }
                let id3 = tag.data
                try file.write(contentsOf: id3)
                let start = range?.start.seconds ?? 0, length = range?.duration.seconds ?? duration
                var reported = -1.0
                while let buffer = output.copyNextSampleBuffer() {
                    try Task.checkCancellation()
                    guard let pcm = try buffer.dataBuffer?.dataBytes() else { continue }
                    try file.write(contentsOf: pcm.withUnsafeBytes { try encoder.encode($0.bindMemory(to: Int16.self)) })
                    let done = (buffer.presentationTimeStamp.seconds - start) / max(length, 1)
                    if done - reported >= 0.005 { reported = done; progress(min(max(done, 0), 1)) }
                }
                if reader.status != .completed { throw reader.error ?? Failure(errorDescription: "Decoding stopped early") }
                try file.write(contentsOf: encoder.flush())
                let lameTag = encoder.lameTag
                if !lameTag.isEmpty {
                    try file.seek(toOffset: UInt64(id3.count))
                    try file.write(contentsOf: lameTag)
                }
            } catch {
                try? FileManager.default.removeItem(at: url)
                throw error
            }
        }

        guard options.splitChapters, !tag.chapters.isEmpty else {
            let file = destination.pathExtension.isEmpty ? destination.appendingPathExtension("mp3") : destination
            return try encode(nil, tag, to: file, progress: progress)
        }
        let created = !FileManager.default.fileExists(atPath: destination.path)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        do {
            let digits = max(2, String(tag.chapters.count).count)
            for (i, c) in tag.chapters.enumerated() {
                var t = tag
                t.title = c.title
                t.track = "\(i + 1)/\(tag.chapters.count)"
                t.chapters = []
                let name = String(format: "%0\(digits)d - ", i + 1) + Book.fileName(c.title, fallback: "Chapter") + ".mp3"
                let range = CMTimeRange(start: CMTime(value: Int64(c.startMs), timescale: 1000),
                                        duration: CMTime(value: Int64(c.lengthMs), timescale: 1000))
                try encode(range, t, to: destination.appendingPathComponent(name)) { p in
                    progress((c.start + p * Double(c.lengthMs) / 1000) / max(duration, 1))
                }
            }
        } catch {
            if created { try? FileManager.default.removeItem(at: destination) }
            throw error
        }
    }

    static func chapters(of asset: AVAsset) async throws -> [Chapter] {
        guard let locale = try await asset.load(.availableChapterLocales).first else { return [] }
        var out: [Chapter] = []
        for group in try await asset.loadChapterMetadataGroups(withTitleLocale: locale, containingItemsWithCommonKeys: []) {
            let item = AVMetadataItem.metadataItems(from: group.items, filteredByIdentifier: .commonIdentifierTitle).first
            let title = try await item?.load(.stringValue) ?? ""
            guard let start = Chapter.millis(group.timeRange.start.seconds),
                  let length = Chapter.millis(group.timeRange.duration.seconds) else { continue }
            out.append(Chapter(title: title, startMs: start, lengthMs: length))
        }
        return out
    }
}
#endif

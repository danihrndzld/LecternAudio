import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct ActivationBytes: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let hex: String

    public init(_ value: String) throws {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.utf8.count == 8,
              normalized.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw ConversionError.invalidActivationBytes
        }
        hex = normalized
    }

    public var description: String { "<activation bytes>" }
    public var debugDescription: String { description }
    public var keychainValue: String { hex }
}

public enum ConversionError: Error, LocalizedError, Equatable {
    case invalidActivationBytes, invalidInput, outputExists, ffmpegUnavailable, conversionFailed, invalidOutput, busy

    public var errorDescription: String? {
        switch self {
        case .invalidActivationBytes: "Enter the eight hexadecimal characters of your Audible activation bytes."
        case .invalidInput: "The encrypted audiobook is missing, unreadable or does not match its credentials."
        case .outputExists: "The destination already exists. Choose a different output file."
        case .ffmpegUnavailable: "FFmpeg could not start. Check that the conversion tool is installed and executable."
        case .conversionFailed: "Conversion failed. Check the activation bytes, source file, free disk space and FFmpeg installation."
        case .invalidOutput: "FFmpeg produced an unreadable or empty audiobook. The original AAX has been kept."
        case .busy: "A conversion is already running."
        }
    }
}

public struct AAXConversionRequest: Sendable {
    public let input: URL
    public let output: URL
    public let book: Book
    public let cover: URL?

    public init(input: URL, output: URL, book: Book, cover: URL? = nil) {
        self.input = input
        self.output = output
        self.book = book
        self.cover = cover
    }

    var chapters: [Chapter] {
        let sorted = book.chapters.sorted { $0.startMs < $1.startMs }
        var end = 0
        for chapter in sorted {
            let sum = chapter.startMs.addingReportingOverflow(chapter.lengthMs)
            guard chapter.startMs >= end, chapter.lengthMs > 0, !sum.overflow else { return [] }
            end = sum.partialValue
        }
        return sorted
    }

    var metadata: String {
        var lines = [";FFMETADATA1"]
        for chapter in chapters {
            lines += ["[CHAPTER]", "TIMEBASE=1/1000", "START=\(chapter.startMs)",
                      "END=\(chapter.startMs + chapter.lengthMs)", "title=\(Self.escape(chapter.title))"]
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "=", with: "\\=")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: "#", with: "\\#")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: "\\\n")
    }

    func arguments(key: ActivationBytes, metadataURL: URL, temporaryOutput: URL) -> [String] {
        arguments(credentials: .aax(key), metadataURL: metadataURL, temporaryOutput: temporaryOutput)
    }

    func arguments(credentials: ContentCredentials, metadataURL: URL, temporaryOutput: URL) -> [String] {
        var args = ["-hide_banner", "-nostdin", "-loglevel", "error", "-xerror", "-n"] + credentials.arguments + ["-i", input.path,
                    "-f", "ffmetadata", "-i", metadataURL.path]
        if let cover { args += ["-i", cover.path] }
        args += ["-map", "0:a:0", "-c:a", "copy", "-map", cover == nil ? "0:v:0?" : "2:v:0",
                 "-c:v", "copy", "-disposition:v:0", "attached_pic",
                 "-map_metadata", "0", "-map_chapters", chapters.isEmpty ? "0" : "1"]
        let tags = [("title", book.title), ("album", book.title), ("artist", book.author),
                    ("album_artist", book.author), ("composer", book.narratedBy),
                    ("genre", book.genre), ("description", HTMLText.markdown(book.summary))]
        for (name, value) in tags where !value.isEmpty { args += ["-metadata", "\(name)=\(value)"] }
        args += ["-metadata", "ausr=", "-metadata", "media_type=2", "-movflags", "+faststart",
                 "-progress", "pipe:1", "-nostats", "-f", "mp4", temporaryOutput.path]
        return args
    }
}

public actor AAXConverter {
    private var running = false

    public init() {}

    public func convert(_ request: AAXConversionRequest, activationBytes: ActivationBytes, ffmpeg: URL,
                        progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        try await convert(request, credentials: .aax(activationBytes), ffmpeg: ffmpeg, progress: progress)
    }

    public func convert(_ request: AAXConversionRequest, credentials: ContentCredentials, ffmpeg: URL,
                        progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        guard !running else { throw ConversionError.busy }
        running = true
        defer { running = false }
        try Task.checkCancellation()
        let manager = FileManager.default
        guard request.input.isFileURL, request.input.pathExtension.lowercased() == credentials.fileExtension,
              manager.isReadableFile(atPath: request.input.path), request.output.isFileURL,
              request.output.pathExtension.lowercased() == "m4b" else { throw ConversionError.invalidInput }
        guard !manager.fileExists(atPath: request.output.path) else { throw ConversionError.outputExists }
        guard ffmpeg.isFileURL, manager.isExecutableFile(atPath: ffmpeg.path) else { throw ConversionError.ffmpegUnavailable }
        let parent = request.output.deletingLastPathComponent()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        let working = parent.appendingPathComponent(".earmark-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: working, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: working) }
        let metadata = working.appendingPathComponent("chapters.txt")
        let output = working.appendingPathComponent("output.m4b")
        try request.metadata.write(to: metadata, atomically: true, encoding: .utf8)
        let status = try await run(ffmpeg, arguments: request.arguments(credentials: credentials, metadataURL: metadata, temporaryOutput: output),
                                   duration: request.book.seconds, progress: progress)
        guard status == 0 else { throw ConversionError.conversionFailed }
        guard let size = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 else {
            throw ConversionError.invalidOutput
        }
        try await validate(output, ffmpeg: ffmpeg)
        try Task.checkCancellation()
        try manager.moveItem(at: output, to: request.output)
        progress(1)
        return request.output
    }

    public func validate(_ output: URL, ffmpeg: URL) async throws {
        guard output.isFileURL, let size = try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 else {
            throw ConversionError.invalidOutput
        }
        let validation = try await run(ffmpeg, arguments: ["-hide_banner", "-nostdin", "-v", "error", "-xerror",
            "-i", output.path, "-map", "0:a:0", "-t", "1", "-f", "null", "-"], duration: 0, progress: { _ in })
        guard validation == 0 else { throw ConversionError.invalidOutput }
    }

    private func run(_ executable: URL, arguments: [String], duration: Int,
                     progress: @escaping @Sendable (Double) -> Void) async throws -> Int32 {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw ConversionError.ffmpegUnavailable }
        try? pipe.fileHandleForWriting.close()
        let reader = Task.detached {
            defer { try? pipe.fileHandleForReading.close() }
            var pending = Data()
            while let data = try? pipe.fileHandleForReading.read(upToCount: 4096), !data.isEmpty {
                pending.append(data)
                while let newline = pending.firstIndex(of: 10) {
                    let line = String(decoding: pending[..<newline], as: UTF8.self)
                    pending.removeSubrange(...newline)
                    if duration > 0, line.hasPrefix("out_time_us="),
                       let elapsed = Double(line.dropFirst("out_time_us=".count)), elapsed.isFinite {
                        progress(min(0.99, max(0, elapsed / 1_000_000 / Double(duration))))
                    }
                }
                if pending.count > 8192 { pending.removeAll(keepingCapacity: true) }
            }
        }
        do {
            while process.isRunning { try await Task.sleep(for: .milliseconds(100)) }
            await reader.value
            try Task.checkCancellation()
            return process.terminationStatus
        } catch {
            if process.isRunning {
                process.terminate()
                for _ in 0..<20 {
                    if !process.isRunning { break }
                    await Task.detached { try? await Task.sleep(for: .milliseconds(50)) }.value
                }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            process.waitUntilExit()
            await reader.value
            throw error
        }
    }
}

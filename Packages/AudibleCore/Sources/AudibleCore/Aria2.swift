import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The bundled aria2c as an optional byte transport for `ContentDownload`. One process per download and no RPC
/// socket. The signed download URL goes in through stdin (`--input-file=-`), never argv, so `ps` cannot show it.
/// aria2c output can contain that URL: it is parsed here and never logged.
public enum Aria2 {
    public struct Options: Sendable, Equatable {
        /// `-x`, 1...16.
        public var connections = 16
        /// `-s`, 1...16.
        public var split = 16
        /// `-k` in MiB: 1, 4, 8 or 16.
        public var minSplitMiB = 1
        /// MiB/s; 0 means unlimited.
        public var maxSpeedMBps = 0
        public var userAgent = "LecternAudio"
        public init() {}
    }

    /// aria2c exited with `status`, or could not start (`-1`). The caller falls back to URLSession.
    public struct Failure: Error, Equatable {
        public let status: Int32
    }

    public static func arguments(_ options: Options, parentPID: Int32) -> [String] {
        let speed = max(0, options.maxSpeedMBps)
        return [
            "--no-conf=true", "--no-netrc=true", "--enable-rpc=false", "--input-file=-",
            "--continue=true", "--allow-overwrite=true", "--auto-file-renaming=false", "--file-allocation=none",
            "--max-connection-per-server=\(min(16, max(1, options.connections)))",
            "--split=\(min(16, max(1, options.split)))",
            "--min-split-size=\(min(1024, max(1, options.minSplitMiB)))M",
            "--max-overall-download-limit=\(speed == 0 ? "0" : "\(speed)M")",
            "--max-tries=5", "--retry-wait=3", "--connect-timeout=30", "--timeout=60",
            "--check-certificate=true", "--http-accept-gzip=false", "--remote-time=false",
            "--user-agent=\(options.userAgent)",
            "--stop-with-process=\(parentPID)",
            "--summary-interval=0", "--show-console-readout=true", "--console-log-level=error", "--enable-color=false",
        ]
    }

    /// The `--input-file` text for one download, or nil when a value would break its line format.
    public static func input(url: URL, file: URL) -> String? {
        let fields = [url.absoluteString, file.deletingLastPathComponent().path, file.lastPathComponent]
        guard AudibleContent.validDownloadURL(url), file.isFileURL,
              fields.allSatisfy({ !$0.isEmpty && !$0.contains(where: \.isNewline) }) else { return nil }
        return "\(fields[0])\n  dir=\(fields[1])\n  out=\(fields[2])\n"
    }

    public enum Readout: Equatable, Sendable {
        /// `fraction` is nil until the size is known; `speed` in bytes/s; `eta` in seconds.
        case progress(fraction: Double?, speed: Int, eta: Int?)
        case completed, failed
    }

    /// Parses one aria2c 1.37 output line: the console readout `[#gid 1.4MiB/293MiB(0%) CN:16 DL:3.2MiB ETA:1m30s]`
    /// or a "Download Results" row `gid|OK  |  17MiB/s|path`.
    public static func parse(_ line: String) -> Readout? {
        let line = line.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("[#"), line.hasSuffix("]") {
            let fields = line.dropFirst().dropLast().split(separator: " ")
            guard fields.count >= 2 else { return nil }
            var fraction: Double?
            if let open = fields[1].firstIndex(of: "("), let percent = fields[1].firstIndex(of: "%"), open < percent,
               let value = Double(fields[1][fields[1].index(after: open)..<percent]) {
                fraction = min(1, max(0, value / 100))
            }
            var speed = 0
            var eta: Int?
            for field in fields.dropFirst(2) {
                if field.hasPrefix("DL:") { speed = bytes(field.dropFirst(3)) ?? 0 }
                if field.hasPrefix("ETA:") { eta = seconds(field.dropFirst(4)) }
            }
            return .progress(fraction: fraction, speed: speed, eta: eta)
        }
        let columns = line.split(separator: "|", omittingEmptySubsequences: false)
        guard columns.count == 4 else { return nil }
        switch columns[1].trimmingCharacters(in: .whitespaces) {
        case "OK": return .completed
        case "ERR": return .failed
        default: return nil
        }
    }

    static func bytes(_ text: Substring) -> Int? {
        let units: [(String, Double)] = [("TiB", 0x1p40), ("GiB", 0x1p30), ("MiB", 0x1p20), ("KiB", 0x1p10), ("B", 1)]
        guard let unit = units.first(where: { text.hasSuffix($0.0) }),
              let value = Double(text.dropLast(unit.0.count)), value >= 0 else { return nil }
        return Int(value * unit.1)
    }

    static func seconds(_ text: Substring) -> Int? {
        guard !text.isEmpty else { return nil }
        var total = 0, number = 0, digits = false
        for character in text {
            if let digit = character.wholeNumberValue { number = number * 10 + digit; digits = true; continue }
            guard digits, let scale = (["h": 3600, "m": 60, "s": 1] as [Character: Int])[character] else { return nil }
            total += number * scale
            number = 0
            digits = false
        }
        return digits ? nil : total
    }

    /// Downloads `url` into `file` (resuming through aria2's `<file>.aria2` control file). Throws `Failure` when
    /// aria2c fails and `CancellationError` when the task is cancelled (aria2c gets SIGTERM, then SIGKILL).
    public static func download(executable: URL, url: URL, to file: URL, options: Options,
                                progress: @escaping @Sendable (Double?) -> Void) async throws {
        guard let input = input(url: url, file: file) else { throw Failure(status: -1) }
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        process.executableURL = executable
        process.arguments = arguments(options, parentPID: getpid())
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stdout
        do { try process.run() } catch { throw Failure(status: -1) }
        try? stdout.fileHandleForWriting.close()
        #if canImport(Darwin)
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)  // aria2c dying early must not kill the app
        #endif
        try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
        try? stdin.fileHandleForWriting.close()
        let reader = Task.detached {
            defer { try? stdout.fileHandleForReading.close() }
            var pending = Data()
            while let data = try? stdout.fileHandleForReading.read(upToCount: 4096), !data.isEmpty {
                pending.append(data)
                while let end = pending.firstIndex(where: { $0 == 10 || $0 == 13 }) {
                    let line = String(decoding: pending[..<end], as: UTF8.self)
                    pending.removeSubrange(...end)
                    if case .progress(let fraction, _, _) = parse(line), let fraction { progress(min(0.99, fraction)) }
                }
                if pending.count > 8192 { pending.removeAll(keepingCapacity: true) }
            }
        }
        do {
            while process.isRunning { try await Task.sleep(for: .milliseconds(100)) }
            await reader.value
            try Task.checkCancellation()
        } catch {
            if process.isRunning {
                process.terminate()  // SIGTERM: aria2c saves its control file so the next run resumes
                for _ in 0..<100 {
                    if !process.isRunning { break }
                    await Task.detached { try? await Task.sleep(for: .milliseconds(50)) }.value
                }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            process.waitUntilExit()
            await reader.value
            throw CancellationError()
        }
        guard process.terminationStatus == 0 else { throw Failure(status: process.terminationStatus) }
    }
}

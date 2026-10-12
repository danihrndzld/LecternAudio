import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import AudibleCore

private let signed = URL(string: "https://cdn.example.invalid/book.aaxc?Signature=SECRET&Expires=1")!

@Test func aria2ArgumentsNeverContainTheURLAndMapLimits() throws {
    var options = Aria2.Options()
    options.connections = 40
    options.split = 0
    options.minSplitMiB = 8
    options.maxSpeedMBps = 5
    options.userAgent = "LecternAudio/7"
    let arguments = Aria2.arguments(options, parentPID: 42)
    #expect(!arguments.contains { $0.contains("example.invalid") || $0.contains("SECRET") || $0.contains("://") })
    for expected in ["--input-file=-", "--max-connection-per-server=16", "--split=1", "--min-split-size=8M",
                     "--max-overall-download-limit=5M", "--stop-with-process=42", "--user-agent=LecternAudio/7",
                     "--continue=true", "--file-allocation=none", "--check-certificate=true", "--no-conf=true",
                     "--enable-rpc=false", "--auto-file-renaming=false", "--allow-overwrite=true"] {
        #expect(arguments.contains(expected), "\(expected)")
    }
    #expect(Aria2.arguments(Aria2.Options(), parentPID: 1).contains("--max-overall-download-limit=0"))
    #expect(Aria2.arguments(Aria2.Options(), parentPID: 1).contains("--max-connection-per-server=16"))
}

@Test func aria2InputCarriesTheURLAndRejectsLineBreaks() {
    let file = URL(fileURLWithPath: "/tmp/library/sources/B0X.aaxc.aria2part")
    #expect(Aria2.input(url: signed, file: file)
            == "\(signed.absoluteString)\n  dir=/tmp/library/sources\n  out=B0X.aaxc.aria2part\n")
    #expect(Aria2.input(url: signed, file: URL(fileURLWithPath: "/tmp/a\nb/x")) == nil)
    #expect(Aria2.input(url: URL(string: "http://cdn.example.invalid/book")!, file: file) == nil)
}

/// Lines captured from aria2c 1.37.0 (AppleTLS build), file paths shortened.
@Test func aria2ParsesReadoutAndResults() {
    #expect(Aria2.parse("[#c12d2b 1.4MiB/293MiB(0%) CN:16 DL:3.2MiB ETA:1m30s]")
            == .progress(fraction: 0, speed: 3_355_443, eta: 90))
    #expect(Aria2.parse("[#c12d2b 108MiB/293MiB(36%) CN:16 DL:19MiB ETA:9s]")
            == .progress(fraction: 0.36, speed: 19 << 20, eta: 9))
    #expect(Aria2.parse("[#b78c37 95MiB/100MiB(95%) CN:1 DL:5.6MiB]") == .progress(fraction: 0.95, speed: 5_872_025, eta: nil))
    #expect(Aria2.parse("[#b78c37 592KiB/100MiB(0%) CN:16 DL:636KiB ETA:2m39s]")
            == .progress(fraction: 0, speed: 636 << 10, eta: 159))
    #expect(Aria2.parse("[#b78c37 0B/0B CN:1 DL:0B]") == .progress(fraction: nil, speed: 0, eta: nil))
    #expect(Aria2.parse("[#aaaaaa 1GiB/2GiB(50%) CN:4 DL:1KiB ETA:1h2m3s]") == .progress(fraction: 0.5, speed: 1024, eta: 3723))
    #expect(Aria2.parse("c12d2b|OK  |    17MiB/s|/tmp/dl2/b.partial") == .completed)
    #expect(Aria2.parse("5272e4|ERR |       0B/s|/tmp/dl3/n.partial") == .failed)
    #expect(Aria2.parse("64bcfb|INPR|    13MiB/s|/tmp/dl3/c.partial") == nil)
    #expect(Aria2.parse("gid   |stat|avg speed  |path/URI") == nil)
    #expect(Aria2.parse("10/11 18:28:47 [ERROR] CUID#7 - Download aborted. URI=https://x.invalid/nope.dmg") == nil)
    #expect(Aria2.parse("(OK):download completed.") == nil)
    #expect(Aria2.parse("") == nil)
}

private func scratch() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private let audio = Data([0, 0, 0, 16]) + Data("ftypaaxc".utf8) + Data([1, 2, 3, 4])

@Test func acceleratedDownloadSkipsURLSessionAndClearsTheSequentialPartial() async throws {
    let directory = try scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("book.aaxc")
    try Data("OLD".utf8).write(to: destination.appendingPathExtension("partial"))
    let result = try await ContentDownload.fetch(url: signed, destination: destination, transfer: { _ in
        Issue.record("URLSession must not run when aria2 succeeds")
        throw CancellationError()
    }, accelerator: { url, file, _ in
        #expect(url == signed)
        #expect(file == destination.appendingPathExtension("aria2part"))
        try audio.write(to: file)
    })
    #expect(try Data(contentsOf: result) == audio)
    #expect(!FileManager.default.fileExists(atPath: destination.appendingPathExtension("partial").path))
    #expect(!FileManager.default.fileExists(atPath: destination.appendingPathExtension("aria2part").path))
}

@Test func aria2FailureFallsBackToURLSessionFromScratch() async throws {
    let directory = try scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("book.aaxc")
    let parallel = destination.appendingPathExtension("aria2part")
    let result = try await ContentDownload.fetch(url: signed, destination: destination, transfer: { request in
        #expect(request.value(forHTTPHeaderField: "Range")?.hasPrefix("bytes=0-") == true)
        let temporary = directory.appendingPathComponent("chunk")
        try audio.write(to: temporary)
        return (temporary, HTTPURLResponse(url: signed, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }, accelerator: { _, file, _ in
        // A sparse file with a control file, as aria2c leaves it after a failure.
        try Data(count: 4096).write(to: file)
        try Data("ctl".utf8).write(to: file.appendingPathExtension("aria2"))
        throw Aria2.Failure(status: 22)
    })
    #expect(try Data(contentsOf: result) == audio)
    #expect(!FileManager.default.fileExists(atPath: parallel.path))
    #expect(!FileManager.default.fileExists(atPath: parallel.appendingPathExtension("aria2").path))
}

@Test func aria2CancellationDoesNotFallBackAndKeepsItsPartial() async throws {
    let directory = try scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("book.aaxc")
    let parallel = destination.appendingPathExtension("aria2part")
    await #expect(throws: CancellationError.self) {
        try await ContentDownload.fetch(url: signed, destination: destination, transfer: { _ in
            Issue.record("URLSession must not run after a cancelled aria2 download")
            throw CancellationError()
        }, accelerator: { _, file, _ in
            try Data(count: 16).write(to: file)
            throw CancellationError()
        })
    }
    #expect(FileManager.default.fileExists(atPath: parallel.path))
}

@Test func disabledAria2RemovesItsStalePartial() async throws {
    let directory = try scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("book.aaxc")
    let parallel = destination.appendingPathExtension("aria2part")
    try Data(count: 4096).write(to: parallel)
    _ = try await ContentDownload.fetch(url: signed, destination: destination, transfer: { _ in
        let temporary = directory.appendingPathComponent("chunk")
        try audio.write(to: temporary)
        return (temporary, HTTPURLResponse(url: signed, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    })
    #expect(!FileManager.default.fileExists(atPath: parallel.path))
}

import Foundation
import Testing
@testable import AudibleCore

private func conversionBook() throws -> Book {
    try JSONDecoder().decode(Book.self, from: Data("""
    {"asin":"test-book","title":"Test Book","author":"An Author","seconds":2,
     "chapters":[{"title":"One","start_offset_ms":0,"length_ms":1000},
                 {"title":"Two","start_offset_ms":1000,"length_ms":1000}],
     "files":[{"path":"Test Book.aax","type":"AAX"}]}
    """.utf8))
}

private func temporaryConversionDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("lectern-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func fakeFFmpeg(in root: URL, body: String) throws -> URL {
    let url = root.appendingPathComponent("ffmpeg")
    try ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    return url
}

@Test func activationBytesRejectMalformedInputAndHideDescriptions() throws {
    for value in ["", "123", "123456789", "gggggggg", "０１２３４５６７", "$(exit)"] {
        #expect(throws: ConversionError.invalidActivationBytes) { try ActivationBytes(value) }
    }
    let key = try ActivationBytes("  " + String(repeating: "A", count: 8) + "\n")
    #expect(key.hex == String(repeating: "a", count: 8))
    #expect(!String(describing: key).contains(key.hex))
    #expect(!String(reflecting: key).contains(key.hex))
}

@Test func conversionCopiesAudioAndMapsChaptersAndArtwork() throws {
    var book = try conversionBook()
    book.chapters[0].title = "one=two;#\\\nnext"
    let root = URL(fileURLWithPath: "/tmp/a directory")
    let input = root.appendingPathComponent("input $(echo).aax")
    let output = root.appendingPathComponent("output.m4b")
    let metadata = root.appendingPathComponent("chapters.txt")
    let key = try ActivationBytes(String(repeating: "0", count: 8))
    let request = AAXConversionRequest(input: input, output: output, book: book)
    let args = request.arguments(key: key, metadataURL: metadata, temporaryOutput: output)
    #expect(args.contains(input.path))
    #expect(args.firstIndex(of: "-activation_bytes")! < args.firstIndex(of: "-i")!)
    #expect(args[args.firstIndex(of: "-c:a")! + 1] == "copy")
    #expect(args[args.firstIndex(of: "-map_chapters")! + 1] == "1")
    #expect(args.contains("0:v:0?"))
    #expect(args.contains("-n"))
    #expect(!args.contains("-y"))
    #expect(request.metadata.contains("title=one\\=two\\;\\#\\\\\\\nnext"))
    #expect(request.metadata.contains("START=1000\nEND=2000"))
    let withCover = AAXConversionRequest(input: input, output: output, book: book, cover: root.appendingPathComponent("cover.jpg"))
    #expect(withCover.arguments(key: key, metadataURL: metadata, temporaryOutput: output).contains("2:v:0"))
    book.chapters[0].lengthMs = Int.max
    let malformed = AAXConversionRequest(input: input, output: output, book: book)
    #expect(malformed.chapters.isEmpty)
    let fallback = malformed.arguments(key: key, metadataURL: metadata, temporaryOutput: output)
    #expect(fallback[fallback.firstIndex(of: "-map_chapters")! + 1] == "0")
}

@Test func convertedLibrarySurvivesReloadWithoutChangingOpenAudibleJSON() throws {
    let root = try temporaryConversionDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let original = Data("""
    [{"asin":"test-book","unknown_future_field":{"keep":true},
      "files":[{"path":"Test Book.aax","type":"AAX"}]}]
    """.utf8)
    try original.write(to: root.appendingPathComponent("books.json"))
    let library = try OpenAudibleLibrary(root: root)
    let book = try #require(library.books.first)
    let output = try #require(library.conversionOutput(for: book))
    try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("audio".utf8).write(to: output)
    try library.recordConversion(for: book, output: output)
    let reloaded = try OpenAudibleLibrary(root: root)
    #expect(reloaded.books[0].hasAudio)
    #expect(reloaded.audioURL(for: reloaded.books[0]) == output)
    #expect(try Data(contentsOf: root.appendingPathComponent("books.json")) == original)
    try FileManager.default.removeItem(at: output)
    #expect(try !OpenAudibleLibrary(root: root).books[0].hasAudio)
    try Data("{\"test-book\":\"../../outside.m4b\"}".utf8)
        .write(to: root.appendingPathComponent("earmark-conversions.json"))
    #expect(try !OpenAudibleLibrary(root: root).books[0].hasAudio)
}

@Test func conversionPublishesOnlyAfterSuccessAndRefusesOverwrite() async throws {
    let root = try temporaryConversionDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let input = root.appendingPathComponent("source.aax")
    let output = root.appendingPathComponent("result.m4b")
    let original = Data("source".utf8)
    try original.write(to: input)
    let executable = try fakeFFmpeg(in: root, body: """
    for argument in "$@"; do last="$argument"; done
    if [ "$last" != "-" ]; then printf audio > "$last"; fi
    printf 'out_time_us=1000000\nprogress=end\n'
    """)
    let converter = AAXConverter()
    let key = try ActivationBytes(String(repeating: "0", count: 8))
    let request = AAXConversionRequest(input: input, output: output, book: try conversionBook())
    #expect(try await converter.convert(request, activationBytes: key, ffmpeg: executable) == output)
    #expect(try Data(contentsOf: input) == original)
    await #expect(throws: ConversionError.outputExists) {
        try await converter.convert(request, activationBytes: key, ffmpeg: executable)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(".lectern-") })
}

@Test(arguments: [false, true]) func failedConversionRemovesPartialOutput(validationFailure: Bool) async throws {
    let root = try temporaryConversionDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let input = root.appendingPathComponent("source.aax")
    let output = root.appendingPathComponent("result.m4b")
    try Data("source".utf8).write(to: input)
    let executable = try fakeFFmpeg(in: root, body: """
    for argument in "$@"; do last="$argument"; done
    if [ "$last" = "-" ]; then exit 1; fi
    printf partial > "$last"
    exit \(validationFailure ? 0 : 1)
    """)
    let request = AAXConversionRequest(input: input, output: output, book: try conversionBook())
    let key = try ActivationBytes(String(repeating: "0", count: 8))
    await #expect(throws: validationFailure ? ConversionError.invalidOutput : .conversionFailed) {
        try await AAXConverter().convert(request, activationBytes: key, ffmpeg: executable)
    }
    #expect(!FileManager.default.fileExists(atPath: output.path))
    #expect(FileManager.default.fileExists(atPath: input.path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(".lectern-") })
}

@Test func cancellationStopsProcessAndRemovesPartialOutput() async throws {
    let root = try temporaryConversionDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let input = root.appendingPathComponent("source.aax")
    let output = root.appendingPathComponent("result.m4b")
    try Data("source".utf8).write(to: input)
    let executable = try fakeFFmpeg(in: root, body: """
    for argument in "$@"; do last="$argument"; done
    printf partial > "$last"
    exec sleep 30
    """)
    let request = AAXConversionRequest(input: input, output: output, book: try conversionBook())
    let key = try ActivationBytes(String(repeating: "0", count: 8))
    let task = Task { try await AAXConverter().convert(request, activationBytes: key, ffmpeg: executable) }
    try await Task.sleep(for: .milliseconds(200))
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(!FileManager.default.fileExists(atPath: output.path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(".lectern-") })
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["LECTERN_TEST_FFMPEG"] != nil))
func realFFmpegRemuxPreservesChapters() async throws {
    let executable = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LECTERN_TEST_FFMPEG"]))
    let root = try temporaryConversionDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source.aax")
    let output = root.appendingPathComponent("result.m4b")
    let generate = Process()
    generate.executableURL = executable
    generate.arguments = ["-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=2",
                          "-c:a", "aac", "-f", "mp4", source.path]
    try generate.run()
    generate.waitUntilExit()
    #expect(generate.terminationStatus == 0)
    let request = AAXConversionRequest(input: source, output: output, book: try conversionBook())
    let key = try ActivationBytes(String(repeating: "0", count: 8))
    _ = try await AAXConverter().convert(request, activationBytes: key, ffmpeg: executable)
    let inspect = Process()
    let pipe = Pipe()
    inspect.executableURL = executable
    inspect.arguments = ["-v", "error", "-i", output.path, "-f", "ffmetadata", "-"]
    inspect.standardOutput = pipe
    try inspect.run()
    let metadata = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    inspect.waitUntilExit()
    #expect(inspect.terminationStatus == 0)
    #expect(metadata.contains("title=Test Book"))
    #expect(metadata.contains("artist=An Author"))
    #expect(metadata.components(separatedBy: "[CHAPTER]").count == 3)
    #expect(metadata.contains("title=One"))
    #expect(metadata.contains("title=Two"))
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["LECTERN_TEST_AAX"] != nil))
func encryptedAAXConvertsAndRejectsWrongKey() async throws {
    let environment = ProcessInfo.processInfo.environment
    let executable = URL(fileURLWithPath: try #require(environment["LECTERN_TEST_FFMPEG"]))
    let source = URL(fileURLWithPath: try #require(environment["LECTERN_TEST_AAX"]))
    let key = try ActivationBytes(try #require(environment["LECTERN_TEST_AAX_KEY"]))
    let root = try temporaryConversionDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    var book = try conversionBook()
    book.chapters = []
    let output = root.appendingPathComponent("converted.m4b")
    let request = AAXConversionRequest(input: source, output: output, book: book)
    _ = try await AAXConverter().convert(request, activationBytes: key, ffmpeg: executable)
    #expect(FileManager.default.fileExists(atPath: output.path))
    let rejected = root.appendingPathComponent("rejected.m4b")
    let wrongKey = try ActivationBytes(String(repeating: key.hex.first == "0" ? "1" : "0", count: 8))
    await #expect(throws: ConversionError.conversionFailed) {
        try await AAXConverter().convert(AAXConversionRequest(input: source, output: rejected, book: book),
                                         activationBytes: wrongKey, ffmpeg: executable)
    }
    #expect(!FileManager.default.fileExists(atPath: rejected.path))
}

@Test func aaxIsTrashedOnlyWhenTheOutputHasTheBooksFullLength() {
    #expect(AAXConverter.durationMatches(36_030.5, expected: 36_000))   // Audible rounds to whole minutes
    #expect(AAXConverter.durationMatches(35_910, expected: 36_000))
    #expect(!AAXConverter.durationMatches(35_000, expected: 36_000))   // truncated
    #expect(!AAXConverter.durationMatches(nil, expected: 36_000))      // unreadable output
    #expect(!AAXConverter.durationMatches(.nan, expected: 36_000))
    #expect(!AAXConverter.durationMatches(0, expected: 36_000))
    #expect(!AAXConverter.durationMatches(60, expected: 0))            // length unknown
}

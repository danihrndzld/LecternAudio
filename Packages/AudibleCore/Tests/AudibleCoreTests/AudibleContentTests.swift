import Crypto
import CryptoExtras
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import AudibleCore

private func registeredAccount() throws -> AudibleAccount {
    let url = try #require(Bundle.module.url(forResource: "Fixtures/register-response.json", withExtension: nil))
    return try SignIn(marketplace: Marketplace.all[0]).account(fromRegisterResponse: Data(contentsOf: url))
}

@Test func registrationKeepsCookiesAndVoucherIdentity() throws {
    let account = try registeredAccount()
    #expect(account.customerID == "REDACTED")
    #expect(account.websiteCookies?.first?["Name"] == "session-token")
    let restored = try JSONDecoder().decode(AudibleAccount.self, from: JSONEncoder().encode(account))
    #expect(restored.websiteCookies == account.websiteCookies)
    #expect(restored.storageID == account.storageID)
    var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(account)) as? [String: Any])
    legacy.removeValue(forKey: "customerID")
    legacy.removeValue(forKey: "websiteCookies")
    let old = try JSONDecoder().decode(AudibleAccount.self, from: JSONSerialization.data(withJSONObject: legacy))
    #expect(old.customerID == nil)
    #expect(!old.refreshToken.isEmpty)
}

@Test func activationResponseUsesLittleEndianAndRejectsErrorPages() throws {
    var blob = Data("group_id=".utf8)
    var body = Data(repeating: 0, count: 568)
    body[0] = 1
    body[1] = 2
    body[2] = 3
    body[3] = 4
    blob.append(body)
    #expect(try AudibleContent.activation(from: blob).hex == "04030201")
    #expect(throws: AudibleError.self) { try AudibleContent.activation(from: Data("BAD_LOGIN".utf8)) }
}

@Test func contentLicenseRequiresGrantAndMatchingBook() throws {
    let account = try registeredAccount()
    #expect(throws: AudibleError.self) {
        try AudibleContent.license(from: Data(#"{"content_license":{"status_code":"Denied","asin":"BOOK"}}"#.utf8), asin: "BOOK", account: account)
    }
    #expect(throws: AudibleError.self) {
        try AudibleContent.license(from: Data(#"{"content_license":{"status_code":"Granted","asin":"OTHER"}}"#.utf8), asin: "BOOK", account: account)
    }
}

@Test func contentCredentialsAreValidatedAndRedacted() throws {
    let key = String(repeating: "ab", count: 16)
    let credential = try ContentCredentials.aaxc(key: key, iv: String(repeating: "cd", count: 16))
    #expect(!String(describing: credential).contains(key))
    #expect(!String(reflecting: credential).contains(key))
    #expect(throws: AudibleError.self) { try ContentCredentials.aaxc(key: "bad", iv: "bad") }
}

@Test func decodesVoucherAgainstOpenSSLVector() throws {
    var account = try registeredAccount()
    account.deviceSerial = "TEST"
    let ciphertext = "yYVXFSPPazjc+JLvSbz49R2ncAo3yT8OXFJRl4PEXD4RKQ9VplP32dh6/wnjqhY+EGIdBGo+5j26aaQunPIrYP+EZcj8cAWtZI/dPMpIyKXASsWqV4tEyzlXSxxFViNz"
    let payload: [String: Any] = ["content_license": [
        "status_code": "Granted", "asin": "BOOK", "license_response": ciphertext,
        "content_metadata": ["content_url": ["offline_url": "https://example.invalid/audio"],
                             "chapter_info": ["chapters": [["title": "Opening", "start_offset_ms": 0, "length_ms": 1000]]]]
    ]]
    let data = try JSONSerialization.data(withJSONObject: payload)
    let license = try AudibleContent.license(from: data, asin: "BOOK", account: account)
    #expect(license.credentials.arguments == ["-audible_key", String(repeating: "1", count: 32), "-audible_iv", String(repeating: "2", count: 32)])
    #expect(license.chapters.first?.title == "Opening")
    account.deviceSerial = "OTHER"
    #expect(throws: AudibleError.self) { try AudibleContent.license(from: data, asin: "BOOK", account: account) }
}

@Test func restoresLegacyProfileAndCookieExchange() throws {
    var account = try registeredAccount()
    let oldStorageID = account.storageID
    try account.applyProfile(Data(#"{"user_id":"REDACTED-OTHER"}"#.utf8))
    #expect(account.storageID != oldStorageID)
    #expect(account.profileRequest().value(forHTTPHeaderField: "x-amz-access-token") == account.accessToken)
    try account.applyCookies(Data(#"{"response":{"tokens":{"cookies":{".amazon.com":[{"Name":"session-token","Value":"REDACTED"}]}}}}"#.utf8))
    #expect(account.websiteCookies?.first?["Name"] == "session-token")
    #expect(account.cookiesRequest().url?.host == "www.amazon.com")
    #expect(throws: AudibleError.self) { try account.applyProfile(Data("{}".utf8)) }
    #expect(throws: AudibleError.self) { try account.applyCookies(Data("{}".utf8)) }
}

@Test func aaxcArgumentsPrecedeInput() throws {
    let book = try JSONDecoder().decode(Book.self, from: Data(#"{"asin":"BOOK","title":"Test"}"#.utf8))
    let request = AAXConversionRequest(input: URL(fileURLWithPath: "/tmp/book.aaxc"), output: URL(fileURLWithPath: "/tmp/book.m4b"), book: book)
    let arguments = request.arguments(credentials: try .aaxc(key: String(repeating: "1", count: 32), iv: String(repeating: "2", count: 32)),
                                      metadataURL: URL(fileURLWithPath: "/tmp/chapters"), temporaryOutput: request.output)
    #expect(try #require(arguments.firstIndex(of: "-audible_iv")) < #require(arguments.firstIndex(of: "-i")))
    #expect(!arguments.contains("-activation_bytes"))
}

@Test func resumesDownloadWithoutSendingAccountCredentials() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("book.aaxc")
    let header = Data([0, 0, 0, 16]) + Data("ftypaaxc".utf8)
    try header.write(to: destination.appendingPathExtension("partial"))
    let remote = URL(string: "https://example.invalid/book")!
    let result = try await ContentDownload.fetch(url: remote, destination: destination, transfer: { request in
        #expect(request.value(forHTTPHeaderField: "Range")?.hasPrefix("bytes=12-") == true)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "x-adp-token") == nil)
        #expect(!request.httpShouldHandleCookies)
        let fragment = directory.appendingPathComponent("chunk")
        try Data([1, 2, 3, 4]).write(to: fragment)
        return (fragment, HTTPURLResponse(url: remote, statusCode: 206, httpVersion: nil, headerFields: ["Content-Range": "bytes 12-15/16"])!)
    })
    #expect(try Data(contentsOf: result) == header + Data([1, 2, 3, 4]))
    #expect(!FileManager.default.fileExists(atPath: destination.appendingPathExtension("partial").path))
}

@Test func downloadRejectsWrongRangeAndHTML() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let remote = URL(string: "https://example.invalid/book")!
    for status in [200, 206] {
        let destination = directory.appendingPathComponent("book\(status).aaxc")
        await #expect(throws: AudibleError.self) {
            try await ContentDownload.fetch(url: remote, destination: destination, transfer: { _ in
                let temporary = directory.appendingPathComponent(UUID().uuidString)
                try Data("<html>Login again</html>".utf8).write(to: temporary)
                return (temporary, HTTPURLResponse(url: remote, statusCode: status, httpVersion: nil,
                                                   headerFields: ["Content-Range": "bytes 50-71/100"])!)
            })
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }
}

@Test func queueRestoresInterruptedWorkButKeepsCancelledAndFailedJobs() throws {
    let book = try JSONDecoder().decode(Book.self, from: Data(#"{"asin":"BOOK","title":"Test"}"#.utf8))
    for state in [DownloadJob.State.queued, .licensing, .downloading, .converting, .complete, .failed, .cancelled] {
        let data = try JSONEncoder().encode([DownloadJob(book: book, state: state)])
        let restored = try #require(DownloadJob.restore(from: data).first)
        let expected: DownloadJob.State = [.licensing, .downloading, .converting].contains(state) ? .queued : state
        #expect(restored.state == expected)
        #expect(restored.id == book.id)
    }
    let duplicate = try JSONEncoder().encode([DownloadJob(book: book), DownloadJob(book: book)])
    #expect(try DownloadJob.restore(from: duplicate).count == 1)
    #expect(throws: (any Error).self) { try DownloadJob.restore(from: Data("bad".utf8)) }
}

@Test func serverIgnoringRangeReplacesRatherThanAppendsPartial() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("book.aaxc")
    try Data("OLD-PARTIAL".utf8).write(to: destination.appendingPathExtension("partial"))
    let header = Data([0, 0, 0, 16]) + Data("ftypaaxc".utf8) + Data([1, 2, 3, 4])
    let remote = URL(string: "https://example.invalid/book")!
    _ = try await ContentDownload.fetch(url: remote, destination: destination, transfer: { _ in
        let temporary = directory.appendingPathComponent("chunk")
        try header.write(to: temporary)
        return (temporary, HTTPURLResponse(url: remote, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    })
    #expect(try Data(contentsOf: destination) == header)
}

@Test func cancellationKeepsPreviouslyDownloadedChunks() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("book.aaxc")
    let partial = destination.appendingPathExtension("partial")
    let existing = Data([0, 0, 0, 16]) + Data("ftypaaxc".utf8)
    try existing.write(to: partial)
    await #expect(throws: CancellationError.self) {
        try await ContentDownload.fetch(url: URL(string: "https://example.invalid/book")!, destination: destination,
                                        transfer: { _ in throw CancellationError() })
    }
    #expect(try Data(contentsOf: partial) == existing)
    #expect(!FileManager.default.fileExists(atPath: destination.path))
}

@Test func licenseRequestUsesSignedDeviceAndRejectsPathInjection() throws {
    var account = try registeredAccount()
    let keyURL = try #require(Bundle.module.url(forResource: "Fixtures/test-only-device-key.pem", withExtension: nil))
    account.devicePrivateKey = try String(contentsOf: keyURL, encoding: .utf8)
    let request = try AudibleContent.licenseRequest(asin: "BOOK", account: account)
    #expect(request.url?.path == "/1.0/content/BOOK/licenserequest")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "x-adp-signature") != nil)
    #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
    let payload = try #require(request.httpBody)
    let body = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
    #expect(body["consumption_type"] as? String == "Download")
    #expect(throws: AudibleError.self) { try AudibleContent.licenseRequest(asin: "../OTHER", account: account) }
}

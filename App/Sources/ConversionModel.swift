import AppKit
import AudibleCore
import Observation
import Security

@Observable
final class ConversionModel {
    var book: Book?
    var activationBytes = ""
    var rememberKey = true
    private(set) var isRunning = false
    private(set) var progress = 0.0
    private(set) var message: String?
    private(set) var succeeded = false
    private let converter = AAXConverter()
    private var task: Task<Void, Never>?
    private(set) var usesAccountKey = false

    var ffmpegURL: URL? {
        Bundle.main.executableURL?.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Helpers/ffmpeg")
    }

    func prepare(_ book: Book) {
        guard !isRunning else { return }
        self.book = book
        usesAccountKey = false
        activationBytes = ""
        message = nil
        succeeded = false
        progress = 0
        do { activationBytes = try ActivationKeychain.read(account: book.id) ?? "" }
        catch { message = error.localizedDescription }
    }

    func prepare(_ book: Book, session: AudibleSession, library: LibraryModel) {
        guard !isRunning else { return }
        self.book = book
        activationBytes = ""
        usesAccountKey = true
        isRunning = true
        succeeded = false
        progress = 0
        message = "Activating your Audible account…"
        let identity = session.account?.storageID
        let root = library.library?.root
        task = Task {
            do {
                let key = try await session.activation()
                try Task.checkCancellation()
                guard session.account?.storageID == identity, library.library?.root == root else { throw CancellationError() }
                activationBytes = key.keychainValue
                isRunning = false
                task = nil
                start(libraryModel: library)
            } catch {
                isRunning = false
                task = nil
                message = (error as? AudibleError)?.message ?? "Could not activate this account. Sign in again or retry."
            }
        }
    }

    func start(libraryModel: LibraryModel) {
        guard !isRunning, let book, let library = libraryModel.library,
              let input = library.aaxURL(for: book), let output = library.conversionOutput(for: book) else { return }
        guard let ffmpegURL else {
            message = "The bundled conversion tool is missing. Rebuild or reinstall Lectern Audio."
            return
        }
        let key: ActivationBytes
        do {
            key = try ActivationBytes(activationBytes)
            if !usesAccountKey {
                if rememberKey { try ActivationKeychain.save(activationBytes, account: book.id) }
                else { try ActivationKeychain.delete(account: book.id) }
            }
        } catch {
            message = error.localizedDescription
            return
        }
        activationBytes = ""
        isRunning = true
        message = nil
        succeeded = false
        progress = 0
        let cover = library.artURL(for: book).flatMap { url in
            url.isFileURL && FileManager.default.isReadableFile(atPath: url.path) ? url : nil
        }
        let request = AAXConversionRequest(input: input, output: output, book: book, cover: cover)
        task = Task { [self] in
            defer { isRunning = false; task = nil }
            do {
                // Shares the limit with the download queue's conversions (Settings, Simultaneous conversions).
                let converted = try await Prefs.conversions.run { [converter] in
                    try await converter.convert(request, activationBytes: key, ffmpeg: ffmpegURL) { [weak self] value in
                        Task { @MainActor in
                            guard let self, self.isRunning else { return }
                            self.progress = max(self.progress, value)
                        }
                    }
                }
                do { try library.recordConversion(for: book, output: converted) }
                catch {
                    try? FileManager.default.removeItem(at: converted)
                    throw error
                }
                if libraryModel.library?.root == library.root { libraryModel.reload() }
                progress = 1
                succeeded = true
                Prefs.playCompletionSound()
                message = "Saved to books/Earmark/\(converted.lastPathComponent)"
            } catch is CancellationError {
                message = "Conversion cancelled. Your AAX file is unchanged."
            } catch {
                message = error.localizedDescription
            }
        }
    }

    func cancel() { task?.cancel() }

    func dismiss() {
        guard !isRunning else { return }
        activationBytes = ""
        book = nil
    }
}

private enum ActivationKeychain {
    static func query(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.danihrndzld.lecternaudio.aax",
         kSecAttrAccount as String: account]
    }

    static func read(account: String) throws -> String? {
        var query = query(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        try check(status)
        return (item as? Data).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func save(_ value: String, account: String) throws {
        let data = Data(value.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        let query = query(account: account)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            try check(SecItemAdd(item as CFDictionary, nil))
        } else { try check(status) }
    }

    static func delete(account: String) throws {
        let status = SecItemDelete(query(account: account) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "Could not access the activation bytes in Keychain (\(status))."])
        }
    }
}

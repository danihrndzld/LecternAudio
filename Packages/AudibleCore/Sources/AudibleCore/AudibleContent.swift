import Crypto
import CryptoExtras
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct ContentCredentials: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let arguments: [String]
    let fileExtension: String

    public static func aax(_ activation: ActivationBytes) -> Self {
        Self(arguments: ["-activation_bytes", activation.hex], fileExtension: "aax")
    }

    public static func aaxc(key: String, iv: String) throws -> Self {
        guard [key, iv].allSatisfy({ value in
            value.utf8.count == 32 && value.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
        }) else { throw AudibleError("Audible returned invalid content credentials.") }
        return Self(arguments: ["-audible_key", key, "-audible_iv", iv], fileExtension: "aaxc")
    }

    public var description: String { "<content credentials>" }
    public var debugDescription: String { description }
}

public struct AudibleContentLicense: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let url: URL
    public let credentials: ContentCredentials
    public let chapters: [Chapter]
    public var description: String { "<Audible content license>" }
    public var debugDescription: String { description }
}

public enum AudibleContent {
    public static func activationRequest(account: AudibleAccount) throws -> URLRequest {
        var request = URLRequest(url: URL(string: "https://www.audible.com/license/token?player_manuf=Audible%2CiPhone&action=register&player_model=iPhone")!)
        try account.sign(&request)
        return request
    }

    public static func activation(from data: Data) throws -> ActivationBytes {
        guard data.count >= 568, data.range(of: Data("group_id".utf8)) != nil,
              data.range(of: Data("BAD_LOGIN".utf8)) == nil,
              data.range(of: Data("Whoops".utf8)) == nil else {
            throw AudibleError("Audible could not activate this account. Sign in again and retry.")
        }
        let bytes = Array(data.suffix(568).prefix(4))
        return try ActivationBytes(bytes.reversed().map { String(format: "%02x", $0) }.joined())
    }

    public static func licenseRequest(asin: String, account: AudibleAccount) throws -> URLRequest {
        guard validASIN(asin) else { throw AudibleError("Invalid Audible book identifier.") }
        var request = URLRequest(url: account.marketplace.audibleAPI.appendingPathComponent("1.0/content/\(asin)/licenserequest"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(SignIn.deviceType, forHTTPHeaderField: "X-Device-Type-Id")
        request.setValue("37801821", forHTTPHeaderField: "X-ADP-SW")
        request.setValue("WIFI", forHTTPHeaderField: "X-ADP-Transport")
        request.setValue("120", forHTTPHeaderField: "X-ADP-LTO")
        request.setValue("phone", forHTTPHeaderField: "device_idiom")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "supported_drm_types": ["Adrm"], "quality": "High", "consumption_type": "Download",
            "response_groups": "content_reference,chapter_info"
        ])
        try account.sign(&request)
        return request
    }

    public static func license(from data: Data, asin: String, account: AudibleAccount) throws -> AudibleContentLicense {
        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let license = envelope["content_license"] as? [String: Any] else {
            throw AudibleError("Audible did not grant a download license for this book.")
        }
        guard license["status_code"] as? String == "Granted" else { throw AudibleError(denialMessage(license)) }
        guard license["asin"] as? String == asin else {
            throw AudibleError("Audible did not grant a download license for this book.")
        }
        guard let customer = account.customerID, !customer.isEmpty else {
            throw AudibleError("This session predates download support. Sign out and sign in once to securely update its device registration.")
        }
        guard let metadata = license["content_metadata"] as? [String: Any],
              let contentURL = metadata["content_url"] as? [String: Any],
              let address = contentURL["offline_url"] as? String, let url = URL(string: address),
              validDownloadURL(url), let encoded = license["license_response"] as? String,
              let encrypted = Data(base64Encoded: encoded), !encrypted.isEmpty, encrypted.count % 16 == 0 else {
            throw AudibleError("Audible returned an unsupported download license.")
        }
        let digest = Data(SHA256.hash(data: Data((SignIn.deviceType + account.deviceSerial + customer + asin).utf8)))
        let plaintext: Data
        do {
            plaintext = try AES._CBC.decrypt(encrypted, using: SymmetricKey(data: digest.prefix(16)),
                                            iv: AES._CBC.IV(ivBytes: digest.suffix(16)), noPadding: true)
        } catch { throw AudibleError("Could not decode the Audible content license.") }
        let trimmed = Data(plaintext.reversed().drop(while: { $0 == 0 }).reversed())
        guard let voucher = try? JSONSerialization.jsonObject(with: trimmed) as? [String: Any],
              let key = voucher["key"] as? String, let iv = voucher["iv"] as? String else {
            throw AudibleError("Could not decode the Audible content license. Sign in again and retry.")
        }
        let chapterInfo = metadata["chapter_info"] as? [String: Any]
        let chapterData = chapterInfo?["chapters"] as? [[String: Any]] ?? []
        let chapters = chapterData.compactMap { chapter -> Chapter? in
            guard let start = chapter["start_offset_ms"] as? Int, let length = chapter["length_ms"] as? Int else { return nil }
            return Chapter(title: chapter["title"] as? String ?? "", startMs: start, lengthMs: length)
        }
        return AudibleContentLicense(url: url, credentials: try .aaxc(key: key, iv: iv), chapters: chapters)
    }

    /// Why Audible refused a license. Audible runs one check per `validationType` (`Ownership`, `Membership`,
    /// `AYCL` for the Audible Plus catalog, `Client` for the device) and lists each failed one in
    /// `license_denial_reasons` with a `rejectionReason`. Audible's own `message` can name the customer,
    /// so only the check and reason codes are shown.
    static func denialMessage(_ license: [String: Any]) -> String {
        let reasons = (license["license_denial_reasons"] as? [[String: Any]] ?? []).compactMap { reason -> (type: String, reason: String)? in
            guard let rejection = reason["rejectionReason"] as? String, !rejection.isEmpty else { return nil }
            return (reason["validationType"] as? String ?? "", rejection)
        }
        let types = Set(reasons.map(\.type))
        let explanation = if reasons.contains(where: { $0.reason == "CustomerThrottled" }) {
            "Audible is limiting downloads for this account right now. Wait a day or two, then choose Retry."
        } else if reasons.isEmpty || reasons.contains(where: { $0.reason == "GenericError" }) {
            "Audible refused the download license without a reason, which usually means a temporary problem at Audible. Choose Retry later."
        } else if types.contains("Client") {
            "Audible doesn't accept this Mac's sign-in for this book. Sign out in Settings, sign in again, then choose Retry."
        } else if types.contains("Membership") || types.contains("AYCL") {
            "This book came with an Audible membership or Audible Plus, not a purchase. Audible no longer lets this account download it, because the membership ended or the book left the Plus catalog. It still appears in your Audible library."
        } else if types.contains("Ownership") {
            "Your Audible account doesn't own this book anymore, for example because it was returned. It still appears in your Audible library."
        } else {
            "Audible did not grant a download license for this book."
        }
        let codes = reasons.map { $0.type.isEmpty ? $0.reason : "\($0.type) \($0.reason)" }
        return codes.isEmpty ? explanation : "\(explanation) (Audible: \(codes.joined(separator: ", ")))"
    }

    public static func validASIN(_ asin: String) -> Bool {
        !asin.isEmpty && asin.utf8.count <= 40 && asin.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) }
    }

    public static func validDownloadURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host != nil && url.user == nil && url.password == nil
    }

    public static func checkResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw AudibleError("Audible request failed (HTTP \(status)). Retry or sign in again.")
        }
    }
}

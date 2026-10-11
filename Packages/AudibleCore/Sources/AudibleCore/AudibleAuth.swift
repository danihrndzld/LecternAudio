import Crypto
import CryptoExtras
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Sign-in, device registration, token refresh and request signing for an Audible account.
// Ported from mkb79/audible (MIT): login.py, register.py, auth.py.

public struct Marketplace: Codable, Hashable, Sendable, Identifiable {
    public var id: String { code }
    /// mkb79's country code ("us", "uk"…), used in the OpenID assoc handle.
    public let code: String
    public let name: String
    /// Top-level domain without the dot: "com", "co.uk".
    public let domain: String
    public let marketplaceID: String

    public static let all: [Marketplace] = [
        .init(code: "us", name: "United States", domain: "com", marketplaceID: "AF2M0KC94RCEA"),
        .init(code: "uk", name: "United Kingdom", domain: "co.uk", marketplaceID: "A2I9A3Q2GNFNGQ"),
        .init(code: "de", name: "Germany", domain: "de", marketplaceID: "AN7V1F1VY261K"),
        .init(code: "fr", name: "France", domain: "fr", marketplaceID: "A2728XDNODOQ8T"),
        // OpenAudible uses A1RKKUPIHCS9HS (Amazon.es retail); mkb79 uses the Audible ES id.
        .init(code: "es", name: "Spain", domain: "es", marketplaceID: "ALMIKO4SZCSAR"),
        .init(code: "it", name: "Italy", domain: "it", marketplaceID: "A2N7FU2W2BU2ZC"),
        .init(code: "au", name: "Australia", domain: "com.au", marketplaceID: "AN7EY7DTAW63G"),
        .init(code: "in", name: "India", domain: "in", marketplaceID: "AJO3FBRUE6J4S"),
        .init(code: "jp", name: "Japan", domain: "co.jp", marketplaceID: "A1QAP3MOU4173J"),
        .init(code: "ca", name: "Canada", domain: "ca", marketplaceID: "A2CQZ5RBY40XE"),
        .init(code: "br", name: "Brazil", domain: "com.br", marketplaceID: "A10J1VAYUDTYRN"),
    ]

    var amazonAPI: URL { URL(string: "https://api.amazon.\(domain)")! }
    public var audibleAPI: URL { URL(string: "https://api.audible.\(domain)")! }
}

public struct AudibleError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// One PKCE sign-in attempt: open `url` in a browser, then call `registerRequest(code:)` with the code from the redirect.
public struct SignIn: Sendable {
    public static let deviceType = "A2CZJZGLK2JJVM"
    /// Amazon serves the mobile sign-in page the Audible iOS app gets.
    public static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 15_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"

    public let marketplace: Marketplace
    public let codeVerifier: String
    public let serial: String

    /// Random 32-byte verifier and device serial.
    public init(marketplace: Marketplace) {
        var rng = SystemRandomNumberGenerator()
        let bytes = Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &rng) })
        self.init(marketplace: marketplace, codeVerifier: bytes.base64URL,
                  serial: UUID().uuidString.replacingOccurrences(of: "-", with: ""))
    }

    public init(marketplace: Marketplace, codeVerifier: String, serial: String) {
        self.marketplace = marketplace
        self.codeVerifier = codeVerifier
        self.serial = serial
    }

    public var codeChallenge: String { Data(SHA256.hash(data: Data(codeVerifier.utf8))).base64URL }

    /// Hex of "<serial>#A2CZJZGLK2JJVM" (lowercase, like Python's bytes.hex()).
    public var clientID: String { Data("\(serial)#\(Self.deviceType)".utf8).map { String(format: "%02x", $0) }.joined() }

    public var url: URL {
        let d = marketplace.domain
        var c = URLComponents(string: "https://www.amazon.\(d)/ap/signin")!
        let identifierSelect = "http://specs.openid.net/auth/2.0/identifier_select"
        c.queryItems = [
            ("openid.oa2.response_type", "code"),
            ("openid.oa2.code_challenge_method", "S256"),
            ("openid.oa2.code_challenge", codeChallenge),
            ("openid.return_to", "https://www.amazon.\(d)/ap/maplanding"),
            ("openid.assoc_handle", "amzn_audible_ios_\(marketplace.code)"),
            ("openid.identity", identifierSelect),
            ("pageId", "amzn_audible_ios"),
            ("accountStatusPolicy", "P1"),
            ("openid.claimed_id", identifierSelect),
            ("openid.mode", "checkid_setup"),
            ("openid.ns.oa2", "http://www.amazon.com/ap/ext/oauth/2"),
            ("openid.oa2.client_id", "device:\(clientID)"),
            ("openid.ns.pape", "http://specs.openid.net/extensions/pape/1.0"),
            ("marketPlaceId", marketplace.marketplaceID),
            ("openid.oa2.scope", "device_auth_access"),
            ("forceMobileLayout", "true"),
            ("openid.ns", "http://specs.openid.net/auth/2.0"),
            ("openid.pape.max_auth_age", "0"),
        ].map { URLQueryItem(name: $0, value: $1) }
        return c.url!
    }

    /// True for the final redirect (`/ap/maplanding`); `authorizationCode(from:)` then holds the code, or nil if sign-in failed.
    public static func isRedirect(_ url: URL) -> Bool { url.path.hasSuffix("/ap/maplanding") }

    public static func authorizationCode(from url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "openid.oa2.authorization_code" }?.value.flatMap { $0.isEmpty ? nil : $0 }
    }

    public func registerRequest(code: String) -> URLRequest {
        let body: [String: Any] = [
            "requested_token_type": ["bearer", "mac_dms", "website_cookies", "store_authentication_cookie"],
            "cookies": ["website_cookies": [Any](), "domain": ".amazon.\(marketplace.domain)"],
            "registration_data": [
                "domain": "Device",
                "app_version": "3.56.2",
                "device_serial": serial,
                "device_type": Self.deviceType,
                "device_name": "%FIRST_NAME%%FIRST_NAME_POSSESSIVE_STRING%%DUPE_STRATEGY_1ST%Audible for iPhone",
                "os_version": "15.0.0",
                "software_version": "35602678",
                "device_model": "iPhone",
                "app_name": "Audible",
            ],
            "auth_data": [
                "client_id": clientID,
                "authorization_code": code,
                "code_verifier": codeVerifier,
                "code_algorithm": "SHA-256",
                "client_domain": "DeviceLegacy",
            ],
            "requested_extensions": ["device_info", "customer_info"],
        ]
        var r = URLRequest(url: marketplace.amazonAPI.appendingPathComponent("auth/register"))
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try! JSONSerialization.data(withJSONObject: body)
        return r
    }

    /// Parses the `/auth/register` response (Amazon's error message is thrown when it has no `response.success`).
    public func account(fromRegisterResponse data: Data, now: Date = .now) throws -> AudibleAccount {
        struct Envelope: Decodable {
            struct Response: Decodable { var success: Success?; var error: Failure? }
            struct Failure: Decodable { var code: String?; var message: String? }
            struct Success: Decodable {
                struct Tokens: Decodable {
                    struct Bearer: Decodable { var access_token: String; var refresh_token: String; var expires_in: String }
                    struct MacDMS: Decodable { var adp_token: String; var device_private_key: String }
                    var bearer: Bearer
                    var mac_dms: MacDMS
                }
                struct Extensions: Decodable {
                    struct Device: Decodable { var device_name: String? }
                    struct Customer: Decodable { var name: String?; var given_name: String?; var user_id: String? }
                    var device_info: Device?
                    var customer_info: Customer?
                }
                var tokens: Tokens
                var extensions: Extensions?
            }
            var response: Response
        }
        let response: Envelope.Response
        do {
            response = try JSONDecoder().decode(Envelope.self, from: data).response
        } catch {
            throw AudibleError("Unexpected device registration response.")
        }
        guard let s = response.success else {
            throw AudibleError("Device registration failed: \(response.error?.message ?? response.error?.code ?? "unknown error")")
        }
        let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let rawResponse = raw?["response"] as? [String: Any]
        let success = rawResponse?["success"] as? [String: Any]
        let tokens = success?["tokens"] as? [String: Any]
        return AudibleAccount(
            marketplace: marketplace,
            deviceSerial: serial,
            deviceName: s.extensions?.device_info?.device_name ?? "",
            customerName: s.extensions?.customer_info?.name ?? s.extensions?.customer_info?.given_name ?? "",
            adpToken: s.tokens.mac_dms.adp_token,
            devicePrivateKey: s.tokens.mac_dms.device_private_key,
            accessToken: s.tokens.bearer.access_token,
            refreshToken: s.tokens.bearer.refresh_token,
            expires: now.addingTimeInterval(Double(s.tokens.bearer.expires_in) ?? 0),
            customerID: s.extensions?.customer_info?.user_id,
            websiteCookies: AudibleAccount.normalizedCookies(tokens?["website_cookies"]))
    }
}

/// A registered device. Stored as JSON in the Keychain; never log it.
public struct AudibleAccount: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var marketplace: Marketplace
    public var deviceSerial: String
    public var deviceName: String
    public var customerName: String
    public var adpToken: String
    public var devicePrivateKey: String
    public var accessToken: String
    public var refreshToken: String
    public var expires: Date
    public var customerID: String? = nil
    public var websiteCookies: [[String: String]]? = nil
    public var activationData: String? = nil
    public var description: String { "<Audible account>" }
    public var debugDescription: String { description }

    public var storageID: String {
        SHA256.hash(data: Data("\(marketplace.code):\(customerID ?? deviceSerial)".utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    public var isExpired: Bool { expires < .now.addingTimeInterval(60) }

    public func profileRequest() -> URLRequest {
        var request = URLRequest(url: marketplace.amazonAPI.appendingPathComponent("user/profile"))
        request.setValue(accessToken, forHTTPHeaderField: "x-amz-access-token")
        return request
    }

    public mutating func applyProfile(_ data: Data) throws {
        struct Profile: Decodable { var user_id: String }
        guard let profile = try? JSONDecoder().decode(Profile.self, from: data), !profile.user_id.isEmpty else {
            throw AudibleError("Could not restore the Audible account identity. Sign in again.")
        }
        customerID = profile.user_id
    }

    public func cookiesRequest() -> URLRequest {
        var components = URLComponents()
        components.queryItems = [
            ("app_name", "Audible"), ("app_version", "3.56.2"), ("source_token", refreshToken),
            ("requested_token_type", "auth_cookies"), ("source_token_type", "refresh_token"),
            ("domain", ".amazon.\(marketplace.domain)")
        ].map { URLQueryItem(name: $0, value: $1) }
        var request = URLRequest(url: URL(string: "https://www.amazon.\(marketplace.domain)/ap/exchangetoken/cookies")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data((components.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        return request
    }

    public mutating func applyCookies(_ data: Data) throws {
        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = envelope["response"] as? [String: Any], let tokens = response["tokens"] as? [String: Any],
              let domains = tokens["cookies"] as? [String: Any], !domains.isEmpty else {
            throw AudibleError("Could not restore the Amazon session cookies. Sign in again.")
        }
        let cookies = domains.values.flatMap { Self.normalizedCookies($0) ?? [] }
        guard !cookies.isEmpty else { throw AudibleError("Amazon returned no session cookies. Sign in again.") }
        websiteCookies = cookies
    }

    static func normalizedCookies(_ raw: Any?) -> [[String: String]]? {
        guard let raw = raw as? [[String: Any]] else { return nil }
        return raw.compactMap { cookie in
            guard cookie["Name"] is String, cookie["Value"] is String else { return nil }
            return cookie.compactMapValues { value in
                if let string = value as? String { return string }
                if let number = value as? NSNumber { return number.stringValue }
                return nil
            }
        }
    }

    public func refreshRequest() -> URLRequest {
        var c = URLComponents()
        c.queryItems = [
            ("app_name", "Audible"),
            ("app_version", "3.56.2"),
            ("source_token", refreshToken),
            ("requested_token_type", "access_token"),
            ("source_token_type", "refresh_token"),
        ].map { URLQueryItem(name: $0, value: $1) }
        var r = URLRequest(url: marketplace.amazonAPI.appendingPathComponent("auth/token"))
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        r.setValue("api.amazon.\(marketplace.domain)", forHTTPHeaderField: "x-amzn-identity-auth-domain")
        // Form encoding: "+" must be escaped too (refresh tokens contain it).
        r.httpBody = Data((c.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        return r
    }

    public mutating func applyRefresh(_ data: Data, now: Date = .now) throws {
        struct Token: Decodable { var access_token: String; var expires_in: Int }
        guard let t = try? JSONDecoder().decode(Token.self, from: data) else { throw AudibleError("Could not refresh the Audible session. Sign in again.") }
        accessToken = t.access_token
        expires = now.addingTimeInterval(Double(t.expires_in))
    }

    public func deregisterRequest() -> URLRequest {
        var r = URLRequest(url: marketplace.amazonAPI.appendingPathComponent("auth/deregister"))
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue(accessToken, forHTTPHeaderField: "x-amz-access-token")
        r.httpBody = Data(#"{"deregister_all_existing_accounts":false}"#.utf8)
        return r
    }

    /// Adds `x-adp-*` headers: SHA256withRSA over "METHOD\npath?query\ndate\nbody\nadp_token".
    public func sign(_ request: inout URLRequest, date: Date = .now) throws {
        let url = request.url!
        let c = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let path = (c?.percentEncodedPath ?? "") + (c?.percentEncodedQuery.map { "?" + $0 } ?? "")
        let body = request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
        for (k, v) in try signedHeaders(method: request.httpMethod ?? "GET", path: path, body: body, date: Self.signatureDate(date)) {
            request.setValue(v, forHTTPHeaderField: k)
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("utf-8", forHTTPHeaderField: "Accept-Charset")
    }

    func signedHeaders(method: String, path: String, body: String, date: String) throws -> [String: String] {
        let data = "\(method)\n\(path)\n\(date)\n\(body)\n\(adpToken)"
        // Amazon issues PKCS#1 keys; "unsafe" also accepts sizes below 2048 bits.
        let key = try _RSA.Signing.PrivateKey(unsafePEMRepresentation: devicePrivateKey)
        let sig = try key.signature(for: Data(data.utf8), padding: .insecurePKCS1v1_5)
        return [
            "x-adp-token": adpToken,
            "x-adp-alg": "SHA256withRSA:1.0",
            "x-adp-signature": "\(sig.rawRepresentation.base64EncodedString()):\(date)",
        ]
    }

    /// UTC with microseconds, e.g. "2020-06-29T22:39:34.379198Z".
    static func signatureDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        let t = date.timeIntervalSince1970
        let micros = Int(((t - t.rounded(.down)) * 1_000_000).rounded(.down))
        return f.string(from: Date(timeIntervalSince1970: t.rounded(.down))) + String(format: ".%06dZ", micros)
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

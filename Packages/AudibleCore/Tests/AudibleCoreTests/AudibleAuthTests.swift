import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import AudibleCore

private let us = Marketplace.all.first { $0.code == "us" }!
private let fixedSignIn = SignIn(marketplace: us, codeVerifier: "TESTVERIFIER0123456789abcdefghijklmnopqrstu", serial: "0123456789ABCDEF0123456789ABCDEF")

private func fixture(_ name: String) throws -> Data {
    try Data(contentsOf: #require(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)))
}

private func account(key: String = "") -> AudibleAccount {
    AudibleAccount(marketplace: us, deviceSerial: "S", deviceName: "", customerName: "", adpToken: "TEST-ADP-TOKEN",
                   devicePrivateKey: key, accessToken: "Atna|A", refreshToken: "Atnr|R+/=&x", expires: .distantPast)
}

@Test func marketplacesCoverElevenRegions() {
    #expect(Marketplace.all.count == 11)
    #expect(Set(Marketplace.all.map(\.code)).count == 11)
    #expect(Marketplace.all.first { $0.code == "uk" }?.domain == "co.uk")
}

@Test func signInURLHasPKCEAndDeviceParams() throws {
    let url = fixedSignIn.url
    #expect(url.absoluteString.hasPrefix("https://www.amazon.com/ap/signin?"))
    let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
    let q = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    #expect(q.count == 18)
    // openssl dgst -sha256 -binary | base64url
    #expect(q["openid.oa2.code_challenge"] == "6IonqHaoJNFFXR52y4eid4gEPMqsrp2sSN2f0XDVGWI")
    #expect(q["openid.oa2.code_challenge_method"] == "S256")
    #expect(q["openid.oa2.client_id"] == "device:3031323334353637383941424344454630313233343536373839414243444546234132435a4a5a474c4b324a4a564d")
    #expect(q["openid.return_to"] == "https://www.amazon.com/ap/maplanding")
    #expect(q["openid.assoc_handle"] == "amzn_audible_ios_us")
    #expect(q["marketPlaceId"] == "AF2M0KC94RCEA")
    #expect(q["openid.oa2.scope"] == "device_auth_access")
    #expect(q["openid.mode"] == "checkid_setup")
    #expect(q["pageId"] == "amzn_audible_ios")
    #expect(q["openid.pape.max_auth_age"] == "0")
}

@Test func randomSignInHasVerifierAndSerialShapes() {
    let s = SignIn(marketplace: us)
    #expect(s.codeVerifier.count == 43)
    #expect(s.serial.count == 32 && s.serial == s.serial.uppercased())
}

@Test func parsesRedirect() throws {
    let ok = try #require(URL(string: "https://www.amazon.com/ap/maplanding?openid.oa2.authorization_code=ANcode123&openid.mode=id_res"))
    #expect(fixedSignIn.isRedirect(ok))
    #expect(SignIn.authorizationCode(from: ok) == "ANcode123")
    let failed = try #require(URL(string: "https://www.amazon.com/ap/maplanding?openid.mode=cancel"))
    #expect(fixedSignIn.isRedirect(failed))
    #expect(SignIn.authorizationCode(from: failed) == nil)
    #expect(!fixedSignIn.isRedirect(fixedSignIn.url))
}

@Test func redirectRequiresMarketplaceSignInHost() throws {
    for bad in ["https://evil.example/ap/maplanding?openid.oa2.authorization_code=x",
                "https://www.amazon.com.evil.example/ap/maplanding",
                "https://www.amazon.co.uk/ap/maplanding",
                "http://www.amazon.com/ap/maplanding",
                "https://www.amazon.com/x/ap/maplanding",
                "https://www.amazon.com/ap/maplanding/x"] {
        #expect(!fixedSignIn.isRedirect(try #require(URL(string: bad))), "\(bad)")
    }
    let uk = SignIn(marketplace: try #require(Marketplace.all.first { $0.code == "uk" }))
    #expect(uk.isRedirect(try #require(URL(string: "https://www.amazon.co.uk/ap/maplanding?openid.mode=cancel"))))
}

@Test func registerBody() throws {
    let r = fixedSignIn.registerRequest(code: "ANcode123")
    #expect(r.url?.absoluteString == "https://api.amazon.com/auth/register")
    #expect(r.httpMethod == "POST")
    let data = try #require(r.httpBody)
    let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let auth = try #require(body["auth_data"] as? [String: String])
    #expect(auth["client_id"] == fixedSignIn.clientID)
    #expect(auth["authorization_code"] == "ANcode123")
    #expect(auth["code_verifier"] == fixedSignIn.codeVerifier)
    #expect(auth["code_algorithm"] == "SHA-256")
    #expect(auth["client_domain"] == "DeviceLegacy")
    let reg = try #require(body["registration_data"] as? [String: String])
    #expect(reg["device_serial"] == fixedSignIn.serial)
    #expect(reg["device_type"] == "A2CZJZGLK2JJVM")
    #expect(reg["app_version"] == "3.56.2")
    #expect((body["cookies"] as? [String: Any])?["domain"] as? String == ".amazon.com")
    #expect(body["requested_token_type"] as? [String] == ["bearer", "mac_dms", "website_cookies", "store_authentication_cookie"])
    #expect(body["requested_extensions"] as? [String] == ["device_info", "customer_info"])
}

@Test func parsesRegisterResponse() throws {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let a = try fixedSignIn.account(fromRegisterResponse: fixture("register-response.json"), now: now)
    #expect(a.accessToken == "Atna|REDACTED-ACCESS")
    #expect(a.refreshToken == "Atnr|REDACTED-REFRESH")
    #expect(a.adpToken.hasPrefix("{enc:"))
    #expect(a.devicePrivateKey.hasPrefix("-----BEGIN RSA PRIVATE KEY-----"))
    #expect(a.expires == now.addingTimeInterval(3600))
    #expect(a.customerName == "Dani Test")
    #expect(a.deviceName == "Dani's Audible for iPhone")
    #expect(a.deviceSerial == fixedSignIn.serial)
    #expect(a.marketplace == us)
    // Round-trips through the Keychain JSON.
    let back = try JSONDecoder().decode(AudibleAccount.self, from: JSONEncoder().encode(a))
    #expect(back.adpToken == a.adpToken)
}

@Test func registerErrorIsThrown() {
    let data = Data(#"{"response":{"error":{"code":"InvalidValue","message":"Invalid authorization code"}}}"#.utf8)
    #expect(throws: AudibleError.self) { try fixedSignIn.account(fromRegisterResponse: data) }
}

@Test func refreshBodyIsFormEncoded() throws {
    var a = account()
    let r = a.refreshRequest()
    #expect(r.url?.absoluteString == "https://api.amazon.com/auth/token")
    #expect(r.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
    let body = String(decoding: try #require(r.httpBody), as: UTF8.self)
    var c = URLComponents()
    c.percentEncodedQuery = body
    let q = Dictionary(uniqueKeysWithValues: (c.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    #expect(q == ["app_name": "Audible", "app_version": "3.56.2", "source_token": "Atnr|R+/=&x",
                  "requested_token_type": "access_token", "source_token_type": "refresh_token"])
    #expect(!body.contains("+"))

    let now = Date(timeIntervalSince1970: 0)
    try a.applyRefresh(Data(#"{"access_token":"Atna|NEW","token_type":"bearer","expires_in":3600}"#.utf8), now: now)
    #expect(a.accessToken == "Atna|NEW")
    #expect(a.expires == now.addingTimeInterval(3600))
}

@Test func deregisterRequest() throws {
    let r = account().deregisterRequest()
    #expect(r.url?.absoluteString == "https://api.amazon.com/auth/deregister")
    #expect(r.value(forHTTPHeaderField: "x-amz-access-token") == "Atna|A")
    #expect(String(decoding: try #require(r.httpBody), as: UTF8.self) == #"{"deregister_all_existing_accounts":false}"#)
}

// Expected value from: printf 'GET\n/1.0/library?num_results=100&page=1\n2020-06-29T22:39:34.379198Z\n\nTEST-ADP-TOKEN'
//   | openssl dgst -sha256 -sign Fixtures/test-only-device-key.pem | base64
@Test func signsWithKnownVector() throws {
    let key = String(decoding: try fixture("test-only-device-key.pem"), as: UTF8.self)
    let h = try account(key: key).signedHeaders(method: "GET", path: "/1.0/library?num_results=100&page=1", body: "", date: "2020-06-29T22:39:34.379198Z")
    #expect(h["x-adp-token"] == "TEST-ADP-TOKEN")
    #expect(h["x-adp-alg"] == "SHA256withRSA:1.0")
    #expect(h["x-adp-signature"] == "gHUBhYya+5lTCIqFRjTANvIb4x+04S5Kp+MPOwITusR1wyrp2+vzeisGWGxO0nUnxS2by7cBllkXwKB+hLs1Z1S5IzuRRWLEm8vfpha68WH+9s6dkymZsd864XOs2A/FOHfRI3z3Oq/zoRZxWk84nFo/rkXirU7U3tkRRRbuQixZGduP58LWAPGxRtBGv/R37X2Ixm6ALjXrYCgsaD91/lHifbuvaBDDIgCVdtNG9YW4VeMbxy8WiolPtiiT29Qu6L7MwHuMQgeJeYWxcZgQJ6vVzKPZ+kHNPN5kuuaRz2CLNgYyAA7DfjOItePa/KlSOL9mJ8ML6/n+kGUhAwcKZg==:2020-06-29T22:39:34.379198Z")

    var r = URLRequest(url: URL(string: "https://api.audible.com/1.0/library?num_results=100&page=1")!)
    try account(key: key).sign(&r, date: Date(timeIntervalSince1970: 1593470374.379198))
    #expect(r.value(forHTTPHeaderField: "x-adp-signature") == h["x-adp-signature"])
}

@Test func signatureDateHasMicroseconds() {
    #expect(AudibleAccount.signatureDate(Date(timeIntervalSince1970: 1593470374.5)) == "2020-06-29T22:39:34.500000Z")
}

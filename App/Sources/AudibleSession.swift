import AudibleCore
import Observation
import Security
import SwiftUI
import WebKit

/// The signed-in Audible device, persisted as JSON in the Keychain. Tokens and keys are never logged.
@Observable
final class AudibleSession {
    private(set) var account: AudibleAccount?
    var error: String?
    private var restoring: Task<AudibleAccount, Error>?

    init() {
        // Snapshots and perf runs stay signed out, like a fresh install.
        if Harness.env["LECTERN_SNAPSHOT"] != nil || Harness.env["LECTERN_PERF_CYCLE"] != nil { return }
        account = Keychain.load().flatMap { try? JSONDecoder().decode(AudibleAccount.self, from: $0) }
    }

    /// Registers the device with the code from Amazon's redirect and stores the credentials.
    func register(_ signIn: SignIn, redirect: URL) async {
        guard let code = SignIn.authorizationCode(from: redirect) else {
            error = "Amazon did not return an authorization code. Try signing in again."
            return
        }
        do {
            let (data, response) = try await AudibleHTTP.data(for: signIn.registerRequest(code: code))
            try AudibleContent.checkResponse(response)
            let a = try signIn.account(fromRegisterResponse: data)
            try Keychain.save(JSONEncoder().encode(a))
            account = a
        } catch {
            self.error = error.localizedDescription
        }
    }

    func currentAccount() async throws -> AudibleAccount {
        if let restoring { return try await restoring.value }
        let task = Task { try await restoreAccount() }
        restoring = task
        defer { restoring = nil }
        return try await task.value
    }

    private func restoreAccount() async throws -> AudibleAccount {
        guard var current = account else { throw AudibleError("Sign in to Audible first.") }
        let identity = current.storageID
        let serial = current.deviceSerial
        var changed = false
        if current.isExpired {
            let (data, response) = try await AudibleHTTP.data(for: current.refreshRequest())
            try AudibleContent.checkResponse(response)
            try current.applyRefresh(data)
            changed = true
        }
        if current.customerID == nil {
            let (data, response) = try await AudibleHTTP.data(for: current.profileRequest())
            try AudibleContent.checkResponse(response)
            try current.applyProfile(data)
            changed = true
        }
        if current.websiteCookies?.isEmpty != false {
            let (data, response) = try await AudibleHTTP.data(for: current.cookiesRequest())
            try AudibleContent.checkResponse(response)
            try current.applyCookies(data)
            changed = true
        }
        try Task.checkCancellation()
        guard account?.storageID == identity, account?.deviceSerial == serial else { throw CancellationError() }
        if changed {
            try Keychain.save(JSONEncoder().encode(current))
            account = current
        }
        return current
    }

    func activation() async throws -> ActivationBytes {
        var current = try await currentAccount()
        if let stored = current.activationData { return try ActivationBytes(stored) }
        let (data, response) = try await AudibleHTTP.data(for: AudibleContent.activationRequest(account: current))
        try AudibleContent.checkResponse(response)
        let activation = try AudibleContent.activation(from: data)
        guard account?.storageID == current.storageID else { throw CancellationError() }
        current.activationData = activation.keychainValue
        try Keychain.save(JSONEncoder().encode(current))
        account = current
        return activation
    }

    /// Deregisters the device (best effort, so offline or revoked sessions can still sign out) and deletes the Keychain item.
    func signOut() async {
        let previous = account
        restoring?.cancel()
        Keychain.delete()
        account = nil
        if var a = previous {
            if a.isExpired, let (data, _) = try? await AudibleHTTP.data(for: a.refreshRequest()) {
                try? a.applyRefresh(data)
            }
            _ = try? await AudibleHTTP.data(for: a.deregisterRequest())
        }
    }
}

private enum Keychain {
    static let base: [CFString: Any] = [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: "com.danihrndzld.lecternaudio",
        kSecAttrAccount: "audible",
    ]

    static func load() -> Data? {
        var q = base
        q[kSecReturnData] = true
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }

    static func save(_ data: Data) throws {
        let updated = SecItemUpdate(base as CFDictionary, [kSecValueData: data] as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw AudibleError("Could not update the Keychain (\(updated)).") }
        var q = base
        q[kSecValueData] = data
        q[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw AudibleError("Could not save to the Keychain (\(status)).") }
    }

    static func delete() { SecItemDelete(base as CFDictionary) }
}

/// Marketplace picker, then Amazon's own sign-in page (it handles captcha and 2FA).
struct SignInView: View {
    @Environment(AudibleSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @AppStorage("marketplace") private var marketplaceCode = "us"
    @State private var signIn: SignIn?
    @State private var registering = false

    var body: some View {
        @Bindable var session = session
        Group {
            if registering {
                ProgressView("Registering Lectern Audio with Audible…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let signIn {
                AmazonWebView(signIn: signIn) { redirect in
                    registering = true
                    Task {
                        await session.register(signIn, redirect: redirect)
                        registering = false
                        self.signIn = nil
                        if session.account != nil { dismiss() }
                    }
                }
            } else {
                Form {
                    Picker("Marketplace", selection: $marketplaceCode) {
                        ForEach(Marketplace.all) { Text("\($0.name) (audible.\($0.domain))").tag($0.code) }
                    }
                    Text("Lectern Audio registers itself as an Audible device, like the Audible app on a phone. Your password goes only to Amazon.")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Spacer()
                        Button("Continue") {
                            signIn = Marketplace.all.first { $0.code == marketplaceCode }.map { SignIn(marketplace: $0) }
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                }
                .formStyle(.grouped)
                .frame(width: 460)
                .fixedSize()
            }
        }
        .alert("Sign-in failed", isPresented: Binding { session.error != nil } set: { if !$0 { session.error = nil } }) {
            Button("OK") {}
        } message: {
            Text(session.error ?? "")
        }
    }
}

private struct AmazonWebView: NSViewRepresentable {
    let signIn: SignIn
    let onRedirect: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(signIn: signIn, onRedirect: onRedirect) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()  // every sign-in starts clean; no Amazon cookies outlive it
        let view = WKWebView(frame: .zero, configuration: config)
        view.customUserAgent = SignIn.userAgent
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: signIn.url))
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let signIn: SignIn
        let onRedirect: (URL) -> Void
        init(signIn: SignIn, onRedirect: @escaping (URL) -> Void) { self.signIn = signIn; self.onRedirect = onRedirect }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = action.request.url, signIn.isRedirect(url) else { return .allow }
            onRedirect(url)
            return .cancel
        }
    }
}

struct AccountSettings: View {
    @Environment(AudibleSession.self) private var session
    @Environment(\.openWindow) private var openWindow
    @State private var signingOut = false

    var body: some View {
        Form {
            if let a = session.account {
                LabeledContent("Account", value: a.customerName.isEmpty ? "Signed in" : a.customerName)
                LabeledContent("Marketplace", value: "\(a.marketplace.name) (audible.\(a.marketplace.domain))")
                LabeledContent("Device", value: a.deviceName)
                LabeledContent("Session", value: "Saved securely in Keychain")
                LabeledContent("Website cookies", value: a.websiteCookies == nil ? "Not restored yet" : "Saved securely in Keychain")
                if let error = session.error { Text(error).foregroundStyle(.red).font(.callout) }
                Button("Sign Out") {
                    signingOut = true
                    Task { await session.signOut(); signingOut = false }
                }
                .disabled(signingOut)
            } else {
                LabeledContent("Account", value: "Not signed in")
                Button("Sign In to Audible…") { openWindow(id: SignInView.windowID) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize()
    }
}

extension SignInView {
    static let windowID = "signin"
}

struct AccountCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .appSettings) {
            Button("Sign In to Audible…") { openWindow(id: SignInView.windowID) }
        }
    }
}

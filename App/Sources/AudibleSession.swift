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

    init() { account = Keychain.load().flatMap { try? JSONDecoder().decode(AudibleAccount.self, from: $0) } }

    /// Registers the device with the code from Amazon's redirect and stores the credentials.
    func register(_ signIn: SignIn, redirect: URL) async {
        guard let code = SignIn.authorizationCode(from: redirect) else {
            error = "Amazon did not return an authorization code. Try signing in again."
            return
        }
        do {
            let (data, _) = try await URLSession.shared.data(for: signIn.registerRequest(code: code))
            let a = try signIn.account(fromRegisterResponse: data)
            try Keychain.save(JSONEncoder().encode(a))
            account = a
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Deregisters the device (best effort, so offline or revoked sessions can still sign out) and deletes the Keychain item.
    func signOut() async {
        if var a = account {
            if a.isExpired, let (data, _) = try? await URLSession.shared.data(for: a.refreshRequest()) {
                try? a.applyRefresh(data)
            }
            _ = try? await URLSession.shared.data(for: a.deregisterRequest())
        }
        Keychain.delete()
        account = nil
    }
}

private enum Keychain {
    static let base: [CFString: Any] = [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: "com.danihrndzld.earmark",
        kSecAttrAccount: "audible",
    ]

    static func load() -> Data? {
        var q = base
        q[kSecReturnData] = true
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }

    static func save(_ data: Data) throws {
        delete()
        var q = base
        q[kSecValueData] = data
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
                ProgressView("Registering Earmark with Audible…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let signIn {
                AmazonWebView(url: signIn.url) { redirect in
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
                    Text("Earmark registers itself as an Audible device, like the Audible app on a phone. Your password goes only to Amazon.")
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
    let url: URL
    let onRedirect: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onRedirect: onRedirect) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()  // every sign-in starts clean; no Amazon cookies outlive it
        let view = WKWebView(frame: .zero, configuration: config)
        view.customUserAgent = SignIn.userAgent
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: url))
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onRedirect: (URL) -> Void
        init(onRedirect: @escaping (URL) -> Void) { self.onRedirect = onRedirect }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = action.request.url, SignIn.isRedirect(url) else { return .allow }
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

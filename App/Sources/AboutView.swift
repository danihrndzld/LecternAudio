import AppKit
import AudibleCore
import SwiftUI

enum AppInfo {
    static let repo = URL(string: "https://github.com/danihrndzld/LecternAudio")!
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    static let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    #if arch(arm64)
    static let arch = "arm64"
    #else
    static let arch = "x86_64"
    #endif
    /// "0.1.0 (1) [arm64]"
    static var versionLine: String { "\(version) (\(build)) [\(arch)]" }
    static var system: String { "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)" }
    static var ffmpegBundled: Bool { helperBundled("ffmpeg") }
    static var aria2Bundled: Bool { helperBundled("aria2c") }
    static func helperBundled(_ name: String) -> Bool {
        Bundle.main.bundleURL.appending(path: "Contents/Helpers/\(name)").path.withCString { access($0, X_OK) == 0 }
    }

    /// Prefilled GitHub issue with app and OS versions only; no account or library data.
    static var bugReportURL: URL {
        var c = URLComponents(url: repo.appending(path: "issues/new"), resolvingAgainstBaseURL: false)!
        c.queryItems = [
            URLQueryItem(name: "title", value: "Bug: "),
            URLQueryItem(name: "body", value: "**What happened**\n\n\n**Steps to reproduce**\n1. \n\n**Expected**\n\n\n---\nLectern Audio \(versionLine)\n\(system)\n"),
        ]
        return c.url!
    }
}

/// Opens one reusable AppKit window per id, so Help and File menu windows need no extra scenes.
enum AuxWindow {
    private static var windows: [String: NSWindow] = [:]

    static func show<Content: View>(_ id: String, title: String, resizable: Bool = true, @ViewBuilder content: () -> Content) {
        if let window = windows[id] { window.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentViewController: NSHostingController(rootView: content()))
        window.title = title
        window.styleMask = resizable ? [.titled, .closable, .miniaturizable, .resizable] : [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        windows[id] = window
        window.makeKeyAndOrderFront(nil)
    }
}

struct AboutView: View {
    let session: AudibleSession

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text("Lectern Audio").font(.title.bold())
            Text(AppInfo.versionLine).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            Link("github.com/danihrndzld/LecternAudio", destination: AppInfo.repo).font(.callout)
            if let account = session.account {
                Text("Signed in as \(account.customerName.isEmpty ? "an Audible account" : account.customerName)")
                    .font(.callout)
            }
            Divider()
            VStack(spacing: 4) {
                Text("For personal use. Not affiliated with Audible or Amazon.").fontWeight(.medium)
                Text("LAME 3.100 — GNU LGPL")
                Text("libogg 1.3.6 — BSD")
                Text("libvorbis 1.3.7 — BSD")
                if AppInfo.ffmpegBundled { Text("FFmpeg — GNU LGPL v2.1") }
                if AppInfo.aria2Bundled { Text("aria2 — GNU GPL v2 or later") }
                Text("swift-crypto — Apache License 2.0")
            }
            .font(.caption).foregroundStyle(.secondary)
            Text("Copyright © 2026 Daniel Hernández").font(.caption2).foregroundStyle(.tertiary)
        }
        .multilineTextAlignment(.center)
        .padding(24)
        .frame(width: 360)
    }
}

struct DiagnosticsView: View {
    let library: LibraryModel
    let session: AudibleSession

    private var report: String {
        let b = library.books
        return """
        Lectern Audio \(AppInfo.versionLine)
        \(AppInfo.system)
        FFmpeg bundled: \(AppInfo.ffmpegBundled ? "yes" : "no")
        Library folder: \(library.library == nil ? "none" : "open")
        Signed in to Audible: \(session.account == nil ? "no" : "yes")
        Last sync: \(library.lastSync?.formatted(date: .abbreviated, time: .shortened) ?? "never")
        Books: \(b.count) (\(library.totalHours) hours)
        Downloaded: \(library.count(.downloaded))
        Not converted: \(library.count(.notConverted))
        In Audible only: \(library.count(.audibleOnly))
        With PDF: \(library.count(.pdfs))
        Imported files: \(library.imported.count)
        Running jobs: \(library.isRunningJobs ? "yes" : "no")
        """
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(report).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report, forType: .string)
                }
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

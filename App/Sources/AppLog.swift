import Observation
import os
import SwiftUI

/// In-app log (File ▸ Log Window) mirrored to the unified log. Never pass tokens, cookies or keys here.
@Observable
final class AppLog {
    static let shared = AppLog()
    private(set) var lines: [String] = []
    private let logger = Logger(subsystem: "com.danihrndzld.lecternaudio", category: "app")

    func info(_ message: String) { append(message, error: false) }
    func error(_ message: String) { append(message, error: true) }

    private func append(_ message: String, error: Bool) {
        if error { logger.error("\(message, privacy: .public)") } else { logger.info("\(message, privacy: .public)") }
        lines.append("\(Date.now.formatted(date: .omitted, time: .standard))  \(error ? "ERROR " : "")\(message)")
        if lines.count > 1000 { lines.removeFirst(lines.count - 1000) }
    }
}

struct LogView: View {
    let log: AppLog

    var body: some View {
        ScrollViewReader { proxy in
            List(Array(log.lines.enumerated()), id: \.offset) { i, line in
                Text(line).font(.system(.caption, design: .monospaced)).textSelection(.enabled).id(i)
            }
            .onChange(of: log.lines.count, initial: true) { _, n in proxy.scrollTo(n - 1, anchor: .bottom) }
        }
        .overlay { if log.lines.isEmpty { ContentUnavailableView("No Log Entries", systemImage: "text.alignleft") } }
        .toolbar {
            Button("Copy", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(log.lines.joined(separator: "\n"), forType: .string)
            }
        }
        .frame(minWidth: 520, minHeight: 300)
    }
}

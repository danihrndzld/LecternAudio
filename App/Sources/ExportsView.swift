import AudibleCore
import SwiftUI

/// The toolbar activity popover: every queued, encoding and finished export, with cancel and retry.
/// Replaces the modal alert a failed export used to raise (issue #5).
struct ExportsView: View {
    let exports: ExportModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Exports").font(.headline)
                Text("Two books are encoded at a time.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            if exports.jobs.isEmpty {
                ContentUnavailableView("No Exports", systemImage: "square.and.arrow.up",
                                       description: Text("Choose Export MP3 or Export Ogg Vorbis for a book."))
                    .frame(height: 150)
            } else {
                Divider()
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(exports.jobs) { job in
                            ExportRow(job: job, exports: exports)
                                .padding(.horizontal, 16)
                            Divider().padding(.leading, 16)
                        }
                    }
                }
                .frame(height: 240)
            }

            Divider()
            HStack {
                Button("Clear Finished") { exports.clearFinished() }
                    .disabled(exports.counts.finished == 0)
                Spacer()
                Button("Cancel All") { exports.cancelAll() }
                    .disabled(!exports.isBusy)
            }
            .padding(16)
        }
        .frame(width: 420)
    }
}

private struct ExportRow: View {
    let job: ExportJob
    let exports: ExportModel

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(job.title).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                if job.state == .running {
                    ProgressView(value: job.progress).controlSize(.small)
                }
            }
            Spacer(minLength: 0)
            action
        }
        .padding(.vertical, 10)
    }

    @ViewBuilder private var action: some View {
        switch job.state {
        case .queued, .running:
            Button("Cancel") { exports.cancel(job.id) }
        case .failed, .cancelled:
            Button("Retry") { exports.retry(job.id) }
        case .complete:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.secondary)
                .help("Finished")
        }
    }

    private var subtitle: String {
        let kind = job.format.name + (job.byChapter ? ", by chapter" : "")
        if let message = job.message { return "\(kind) — \(message)" }
        return switch job.state {
        case .queued: "\(kind) — waiting"
        case .running: "\(kind) — \(Int(job.progress * 100))%"
        default: kind
        }
    }
}

import SwiftUI
import AudibleCore

struct DownloadsView: View {
    @Bindable var downloads: DownloadModel
    let library: LibraryModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Downloads").font(.title2.bold())
            Toggle("Download and convert new books after syncing", isOn: $downloads.automaticallyDownload)
            Text("Downloads stay on this Mac. Your account supplies the credentials automatically; no book keys to enter.")
                .font(.callout).foregroundStyle(.secondary)
            List(downloads.jobs) { job in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(job.book.title).lineLimit(2)
                        Text(job.message ?? job.state.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
                        if downloads.activeID == job.id {
                            if let progress = downloads.progress { ProgressView(value: progress) }
                            else { ProgressView().controlSize(.small) }
                        }
                    }
                    Spacer()
                    if [.failed, .cancelled].contains(job.state) {
                        Button("Retry") { downloads.enqueue([job.book]) }
                    } else if [.queued, .licensing, .downloading, .converting].contains(job.state) {
                        Button("Cancel") { downloads.cancel(job.id) }
                    }
                }
                .padding(.vertical, 4)
            }
            .overlay {
                if downloads.jobs.isEmpty {
                    ContentUnavailableView("No Downloads Yet", systemImage: "arrow.down.circle",
                                           description: Text("Choose a book and select Download and Convert, or download all missing books below."))
                }
            }
            if let error = downloads.error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Button("Download Missing Books") { downloads.enqueue(library.books) }
                    .disabled(!library.books.contains(where: library.canDownload))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 580, height: 460)
    }
}

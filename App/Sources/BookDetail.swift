import AudibleCore
import SwiftUI

struct BookDetail: View {
    @Environment(LibraryModel.self) private var model
    @Environment(Player.self) private var player
    let book: Book

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Cover(url: model.artURL(for: book)).aspectRatio(1, contentMode: .fit).frame(maxWidth: 260).frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 4) {
                    Text(book.title).font(.title2.bold()).textSelection(.enabled)
                    Text(book.author).font(.headline).foregroundStyle(.secondary)
                }

                if let url = model.audioURL(for: book) {
                    Button { player.play(book, url: url) } label: {
                        Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                }

                if let progress = model.exports[book.id] {
                    HStack {
                        ProgressView("Exporting MP3…", value: progress)
                        Button("Cancel", systemImage: "xmark.circle.fill") { model.cancelExport(book.id) }
                            .labelStyle(.iconOnly).buttonStyle(.borderless)
                    }
                } else if model.m4bURL(for: book) != nil {
                    Menu {
                        Button("One File per Chapter…") { model.exportMP3(book, byChapter: true) }
                    } label: {
                        Label("Export MP3…", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                    } primaryAction: {
                        model.exportMP3(book, byChapter: false)
                    }
                }

                if model.library?.aaxURL(for: book) != nil {
                    Button("Convert to M4B…", systemImage: "arrow.triangle.2.circlepath") { model.convert(book) }
                        .disabled(model.conversion.isRunning)
                }

                if model.canDownload(book) {
                    Button("Download and Convert", systemImage: "arrow.down.circle") { model.downloads.enqueue([book]) }
                        .disabled(model.downloads.jobs.contains { $0.id == book.id && [.queued, .licensing, .downloading, .converting].contains($0.state) })
                    if let job = model.downloads.jobs.first(where: { $0.id == book.id }) {
                        Text(job.message ?? job.state.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
                    }
                }

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    field("Narrator", book.narratedBy)
                    field("Length", book.durationText)
                    field("Released", book.releaseDate?.formatted(date: .long, time: .omitted))
                    field("Purchased", book.purchaseDate?.formatted(date: .long, time: .omitted))
                    field("Rating", book.rating.map { "\($0.formatted(.number.precision(.fractionLength(2)))) (\(book.ratingCount ?? 0))" })
                    field("Publisher", book.publisher)
                    field("Genre", book.genre.replacingOccurrences(of: ":", with: " › "))
                    field("ASIN", book.asin)
                }
                .font(.callout)

                if !book.summary.isEmpty {
                    Divider()
                    Text(summary).font(.callout).textSelection(.enabled)
                }

                if book.chapters.count > 1 {
                    Divider()
                    DisclosureGroup("\(book.chapters.count) Chapters", isExpanded: Bindable(model).showChapters) {
                        ForEach(book.chapters, id: \.startMs) { c in
                            HStack {
                                Text(c.title).lineLimit(1)
                                Spacer()
                                Text(Duration.milliseconds(c.lengthMs).formatted(.time(pattern: .hourMinuteSecond)))
                                    .monospacedDigit().foregroundStyle(.secondary)
                            }
                            .font(.callout)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if player.book?.id == book.id { player.seek(to: c.start) }
                                else if let url = model.audioURL(for: book) {
                                    player.play(book, url: url)
                                    player.seek(to: c.start)
                                }
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    private var summary: AttributedString {
        let md = HTMLText.markdown(book.summary)
        return (try? AttributedString(markdown: md, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(md)
    }

    @ViewBuilder private func field(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            GridRow {
                Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                Text(value).textSelection(.enabled)
            }
        }
    }
}

struct PlayerBar: View {
    @Environment(Player.self) private var player
    @Environment(LibraryModel.self) private var model

    var body: some View {
        @Bindable var player = player
        if let book = player.book {
            HStack(spacing: 16) {
                Cover(url: model.thumbURL(for: book), thumbnail: true).frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(book.title).font(.callout.weight(.semibold)).lineLimit(1)
                    Text(player.currentChapter?.title ?? book.author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(width: 220, alignment: .leading)

                Button("Back 30 seconds", systemImage: "gobackward.30") { player.skip(-30) }
                Button(player.isPlaying ? "Pause" : "Play", systemImage: player.isPlaying ? "pause.fill" : "play.fill") { player.toggle() }
                    .font(.title2)
                Button("Forward 30 seconds", systemImage: "goforward.30") { player.skip(30) }

                Text(Duration.seconds(player.time).formatted(.time(pattern: .hourMinuteSecond))).monospacedDigit().font(.caption)
                Slider(value: Binding(get: { player.time }, set: { player.seek(to: $0) }), in: 0...max(player.duration, 1))
                Text(Duration.seconds(player.duration - player.time).formatted(.time(pattern: .hourMinuteSecond))).monospacedDigit().font(.caption)

                Picker("Speed", selection: $player.rate) {
                    ForEach([0.75, 1, 1.25, 1.5, 1.75, 2] as [Float], id: \.self) { Text("\($0.formatted())×").tag($0) }
                }
                .labelsHidden().frame(width: 70)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .glassEffect(.regular, in: .rect(cornerRadius: 16))
            .padding(12)
            // Report no minimum width: the bar appearing must not raise the split view's detail-column min size,
            // which AppKit applies mid constraint pass and crashes ("needs update constraints").
            .frame(minWidth: 0, maxWidth: .infinity)
        }
    }
}

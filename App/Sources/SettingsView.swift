import AudibleCore
import Sparkle
import SwiftUI
import UniformTypeIdentifiers

/// `UserDefaults` keys shared by the Settings panes (`@AppStorage`) and the code that reads them directly.
enum Prefs {
    static let outputFormat = "outputFormat"  // "m4b", "mp3" or "ogg"
    static let mp3Bitrate = "mp3Bitrate"
    static let mp3VBR = "mp3VBR"
    static let oggQuality = "oggQuality"  // 0...10
    static let refreshOnLaunch = "refreshOnLaunch"
    static let autoSync = "autoSync"
    static let autoSyncHours = "autoSyncHours"
    static let showProgress = "showProgress"
    static let language = "language"  // "" follows the system
    static let appearance = "appearance"  // "system", "light", "dark"
    static let tableFontSize = "tableFontSize"  // "small", "medium", "large"
    static let completionSound = "completionSound"
    static let externalPlayer = "externalPlayer"
    static let playerApp = "playerApp"
    static let browserApp = "browserApp"
    static let fileManagerApp = "fileManagerApp"
    static let maxDownloads = "maxDownloads"
    static let maxConversions = "maxConversions"
    static let aria2 = "aria2"
    static let aria2Connections = "aria2Connections"
    static let aria2Split = "aria2Split"
    static let aria2MinSplitMiB = "aria2MinSplitMiB"
    static let aria2MaxSpeedMBps = "aria2MaxSpeedMBps"  // 0 = unlimited

    /// Defaults for non-view readers; the `@AppStorage` declarations below repeat the same values.
    static func register() {
        UserDefaults.standard.register(defaults: [
            outputFormat: "m4b", mp3Bitrate: 320, oggQuality: 10, refreshOnLaunch: true, autoSync: true, autoSyncHours: 24,
            appearance: "system", tableFontSize: "medium",
            maxDownloads: DownloadQueue.defaultDownloads, maxConversions: DownloadQueue.defaultConversions,
            aria2Connections: 16, aria2Split: 16, aria2MinSplitMiB: 1, aria2MaxSpeedMBps: 0,
        ])
    }

    static var mp3Options: MP3Export.Options {
        var options = MP3Export.Options()
        let bitrate = UserDefaults.standard.integer(forKey: mp3Bitrate)
        options.bitrate = MP3Encoder.bitrates.contains(bitrate) ? bitrate : 320
        options.mode = UserDefaults.standard.bool(forKey: mp3VBR) ? .vbr : .cbr
        return options
    }

    static var oggOptions: OggExport.Options {
        var options = OggExport.Options()
        options.quality = min(max(UserDefaults.standard.integer(forKey: oggQuality), 0), 10)
        return options
    }

    /// The bundled aria2c as the download transport, or nil when it is off or missing. A failure is logged with the
    /// host only (the query string is the signature) and `ContentDownload` falls back to URLSession.
    static var aria2Accelerator: ContentDownload.Accelerator? {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: aria2), AppInfo.aria2Bundled else { return nil }
        let helper = Bundle.main.bundleURL.appending(path: "Contents/Helpers/aria2c")
        var options = Aria2.Options()
        options.connections = defaults.integer(forKey: aria2Connections)
        options.split = defaults.integer(forKey: aria2Split)
        options.minSplitMiB = defaults.integer(forKey: aria2MinSplitMiB)
        options.maxSpeedMBps = defaults.integer(forKey: aria2MaxSpeedMBps)
        // URLSession's default User-Agent starts with the same "<escaped app name>/<build>".
        let name = (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "LecternAudio")
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "LecternAudio"
        options.userAgent = "\(name)/\(AppInfo.build)"
        return { [options] url, file, progress in
            do { try await Aria2.download(executable: helper, url: url, to: file, options: options, progress: progress) }
            catch {
                if !(error is CancellationError) {
                    let status = (error as? Aria2.Failure)?.status ?? -1
                    await AppLog.shared.error("aria2c failed (status \(status)) downloading from \(url.host ?? "unknown host"); retrying with the built-in downloader.")
                }
                throw error
            }
        }
    }

    static var downloadConcurrency: Int {
        UserDefaults.standard.integer(forKey: maxDownloads)
    }

    /// One limiter for every FFmpeg conversion in the app. Download jobs convert inside the job, so
    /// without a shared limit the conversion setting could only ever be as coarse as the download
    /// setting (issue #18).
    static let conversions = ConcurrencyLimiter(limit: DownloadQueue.defaultConversions)

    static func applyConversionLimit() {
        let limit = UserDefaults.standard.integer(forKey: maxConversions)
        Task { await conversions.setLimit(limit) }
    }

    static func playCompletionSound() {
        if UserDefaults.standard.bool(forKey: completionSound) { NSSound(named: "Glass")?.play() }
    }

    /// Opens `url` with the app chosen under `appKey`, or the system default when none is chosen or it fails to open.
    static func open(_ url: URL, appKey: String) {
        guard let path = UserDefaults.standard.string(forKey: appKey), !path.isEmpty else {
            NSWorkspace.shared.open(url)
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: path), configuration: .init()) { _, error in
            if error != nil { Task { @MainActor in NSWorkspace.shared.open(url) } }
        }
    }

    /// Show in Finder, or the chosen file manager opened on the file's folder.
    static func reveal(_ url: URL) {
        if UserDefaults.standard.string(forKey: fileManagerApp)?.isEmpty == false {
            open(url.deletingLastPathComponent(), appKey: fileManagerApp)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}

struct SettingsView: View {
    let updater: SPUUpdater

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings(updater: updater) }
            Tab("Advanced", systemImage: "gearshape.2") { AdvancedSettings() }
            Tab("Account", systemImage: "person.crop.circle") { AccountSettings() }
        }
        .scenePadding()
    }
}

private struct GeneralSettings: View {
    let updater: SPUUpdater
    @AppStorage(Prefs.outputFormat) private var outputFormat = "m4b"
    @AppStorage(Prefs.mp3Bitrate) private var bitrate = 320
    @AppStorage(Prefs.mp3VBR) private var vbr = false
    @AppStorage(Prefs.oggQuality) private var oggQuality = 10
    @AppStorage(Prefs.refreshOnLaunch) private var refreshOnLaunch = true
    @AppStorage(Prefs.autoSync) private var autoSync = true
    @AppStorage(Prefs.autoSyncHours) private var autoSyncHours = 24
    @AppStorage(Prefs.showProgress) private var showProgress = false
    /// Sparkle's own defaults key, read only so the toggle redraws; writes go through the updater.
    @AppStorage("SUEnableAutomaticChecks") private var automaticUpdateChecks = true
    @AppStorage(Prefs.language) private var language = ""
    @AppStorage(Prefs.appearance) private var appearance = "system"
    @AppStorage(Prefs.tableFontSize) private var tableFontSize = "medium"
    @AppStorage(Prefs.completionSound) private var completionSound = false
    @State private var languageChanged = false

    /// libvorbis nominal bitrates for 44.1 kHz stereo; mono and lower sample rates come out smaller.
    static func oggQualityText(_ q: Int) -> String {
        let kbps = [64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 500][min(max(q, 0), 10)]
        return q >= 10 ? "Maximum (q10, about 500 kbps)" : "q\(q), about \(kbps) kbps"
    }

    var body: some View {
        Form {
            Section("Audio Output") {
                Picker("Format", selection: $outputFormat) {
                    Text("M4B").tag("m4b")
                    Text("MP3").tag("mp3")
                    Text("Ogg Vorbis").tag("ogg")
                }
                .pickerStyle(.radioGroup)
                Text(outputFormat == "m4b"
                     ? "Best quality; recommended if your players support it."
                     : "Downloaded books also get an \(outputFormat == "ogg" ? "Ogg Vorbis" : "MP3") copy next to the M4B.")
                    .font(.callout).foregroundStyle(.secondary)
                Picker("MP3 bitrate", selection: $bitrate) {
                    ForEach(MP3Encoder.bitrates, id: \.self) { Text("\($0) kbps").tag($0) }
                }
                Toggle("Variable bitrate (VBR)", isOn: $vbr)
                Text("Used by Export MP3 and MP3 copies. 64 kbps and below are mono.")
                    .font(.callout).foregroundStyle(.secondary)
                Slider(value: Binding(get: { Double(oggQuality) }, set: { oggQuality = Int($0.rounded()) }), in: 0...10, step: 1) {
                    Text("Ogg Vorbis quality")
                }
                Text("Quality: \(Self.oggQualityText(oggQuality)). Used by Export Ogg Vorbis and Ogg copies.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Automation") {
                Toggle("Refresh library on launch", isOn: $refreshOnLaunch)
                Toggle("Show progress automatically when downloads start", isOn: $showProgress)
                Toggle(isOn: $autoSync) {
                    Stepper("Sync with Audible every \(autoSyncHours) hours", value: $autoSyncHours, in: 1...168)
                }
                Toggle("Disable update checks", isOn: Binding(
                    get: { !automaticUpdateChecks }, set: { updater.automaticallyChecksForUpdates = !$0 }))
            }
            Section("Language and Theme") {
                Picker("Language", selection: $language) {
                    Text("System").tag("")
                    Text("English").tag("en")
                    Text("Español").tag("es")
                }
                .onChange(of: language) { _, new in
                    if new.isEmpty { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
                    else { UserDefaults.standard.set([new], forKey: "AppleLanguages") }
                    languageChanged = true
                }
                if languageChanged {
                    Text("Quit and reopen Lectern Audio to apply the language.").font(.callout).foregroundStyle(.secondary)
                }
                Picker("Appearance", selection: $appearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                Picker("Library font size", selection: $tableFontSize) {
                    Text("Small").tag("small")
                    Text("Medium").tag("medium")
                    Text("Large").tag("large")
                }
                Toggle("Play a sound when a download, conversion or export finishes", isOn: $completionSound)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .fixedSize()
    }
}

private struct AdvancedSettings: View {
    @Environment(LibraryModel.self) private var library
    @AppStorage(Prefs.externalPlayer) private var externalPlayer = false
    @AppStorage(Prefs.maxDownloads) private var maxDownloads = DownloadQueue.defaultDownloads
    @AppStorage(Prefs.maxConversions) private var maxConversions = DownloadQueue.defaultConversions
    @AppStorage(Prefs.aria2) private var aria2 = false
    @AppStorage(Prefs.aria2Connections) private var connections = 16
    @AppStorage(Prefs.aria2Split) private var split = 16
    @AppStorage(Prefs.aria2MinSplitMiB) private var minSplit = 1
    @AppStorage(Prefs.aria2MaxSpeedMBps) private var maxSpeed = 0

    var body: some View {
        Form {
            Section("Applications") {
                Toggle("Play books in an external player instead of Lectern Audio", isOn: $externalPlayer)
                AppPicker(title: "Audio player", key: Prefs.playerApp)
                AppPicker(title: "Web browser", key: Prefs.browserApp)
                AppPicker(title: "File manager", key: Prefs.fileManagerApp)
            }
            Section("Concurrent Jobs") {
                Stepper("Simultaneous downloads: \(maxDownloads)", value: $maxDownloads, in: DownloadQueue.concurrencyRange)
                    .onChange(of: maxDownloads) { library.downloads.advance() }
                Stepper("Simultaneous conversions: \(maxConversions)", value: $maxConversions, in: DownloadQueue.concurrencyRange)
                    .onChange(of: maxConversions) { Prefs.applyConversionLimit() }
                Text("Downloads mostly wait on the network. Conversions copy the audio stream, so they mostly wait on the disk. A download that is ready to convert waits for a conversion slot, so setting conversions far below downloads leaves downloads idle.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Downloads") {
                Toggle("Use aria2c for faster downloads", isOn: $aria2).disabled(!AppInfo.aria2Bundled)
                Group {
                    Stepper("Connections per server: \(connections)", value: $connections, in: 1...16)
                    Stepper("Split into \(split) parts", value: $split, in: 1...16)
                    Picker("Minimum part size", selection: $minSplit) {
                        ForEach([1, 4, 8, 16], id: \.self) { Text("\($0) MB").tag($0) }
                    }
                    TextField("Speed limit (MB/s)", value: $maxSpeed, format: .number)
                }
                .disabled(!aria2)
                Text("Downloads several parts at once with the bundled aria2c. A speed limit of 0 means no limit. If aria2c fails, the built-in downloader takes over.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .fixedSize()
    }
}

/// An app chosen with an open panel, stored as a path; empty means the system default.
private struct AppPicker: View {
    let title: LocalizedStringKey
    @AppStorage private var path: String

    init(title: LocalizedStringKey, key: String) {
        self.title = title
        _path = AppStorage(wrappedValue: "", key)
    }

    var body: some View {
        LabeledContent(title) {
            HStack {
                if path.isEmpty {
                    Text("System Default").foregroundStyle(.secondary)
                } else {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 16, height: 16)
                    Text(FileManager.default.displayName(atPath: path))
                    Button("Use System Default", systemImage: "xmark.circle.fill") { path = "" }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                }
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.application]
                    panel.directoryURL = URL(fileURLWithPath: "/Applications")
                    if panel.runModal() == .OK, let url = panel.url { path = url.path }
                }
            }
        }
    }
}

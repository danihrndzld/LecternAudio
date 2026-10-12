import AudibleCore
import Sparkle
import SwiftUI
import UniformTypeIdentifiers

/// `UserDefaults` keys shared by the Settings panes (`@AppStorage`) and the code that reads them directly.
enum Prefs {
    static let outputFormat = "outputFormat"  // "m4b" or "mp3"
    static let mp3Bitrate = "mp3Bitrate"
    static let mp3VBR = "mp3VBR"
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

    /// Defaults for non-view readers; the `@AppStorage` declarations below repeat the same values.
    static func register() {
        UserDefaults.standard.register(defaults: [
            outputFormat: "m4b", mp3Bitrate: 64, refreshOnLaunch: true, autoSync: true, autoSyncHours: 24,
            appearance: "system", tableFontSize: "medium",
        ])
    }

    static var mp3Options: MP3Export.Options {
        var options = MP3Export.Options()
        let bitrate = UserDefaults.standard.integer(forKey: mp3Bitrate)
        options.bitrate = MP3Encoder.bitrates.contains(bitrate) ? bitrate : 64
        options.mode = UserDefaults.standard.bool(forKey: mp3VBR) ? .vbr : .cbr
        return options
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
    @AppStorage(Prefs.mp3Bitrate) private var bitrate = 64
    @AppStorage(Prefs.mp3VBR) private var vbr = false
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

    var body: some View {
        Form {
            Section("Audio Output") {
                Picker("Format", selection: $outputFormat) {
                    Text("M4B").tag("m4b")
                    Text("MP3").tag("mp3")
                }
                .pickerStyle(.radioGroup)
                Text(outputFormat == "m4b"
                     ? "Best quality; recommended if your players support it."
                     : "Downloaded books also get an MP3 copy next to the M4B.")
                    .font(.callout).foregroundStyle(.secondary)
                Picker("MP3 bitrate", selection: $bitrate) {
                    ForEach(MP3Encoder.bitrates, id: \.self) { Text("\($0) kbps").tag($0) }
                }
                Toggle("Variable bitrate (VBR)", isOn: $vbr)
                Text("Used by Export MP3 and MP3 copies. 64 kbps and below are mono.")
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
    @AppStorage(Prefs.externalPlayer) private var externalPlayer = false

    var body: some View {
        Form {
            Section("Applications") {
                Toggle("Play books in an external player instead of Lectern Audio", isOn: $externalPlayer)
                AppPicker(title: "Audio player", key: Prefs.playerApp)
                AppPicker(title: "Web browser", key: Prefs.browserApp)
                AppPicker(title: "File manager", key: Prefs.fileManagerApp)
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

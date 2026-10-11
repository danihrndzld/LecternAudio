import AVFoundation
import AppKit
import AudibleCore
import MediaPlayer
import Observation
import WebKit

@Observable
final class Player {
    private(set) var book: Book?
    private(set) var isPlaying = false
    private(set) var time: TimeInterval = 0
    var rate: Float = 1 { didSet { if isPlaying { avPlayer.rate = rate } } }
    var volume: Float = UserDefaults.standard.object(forKey: "volume") as? Float ?? 1 {
        didSet { avPlayer.volume = volume; UserDefaults.standard.set(volume, forKey: "volume") }
    }

    private let avPlayer = AVPlayer()
    private var observer: Any?

    init() {
        observer = avPlayer.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 1), queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.tick(t.seconds) }
        }
        let center = MPRemoteCommandCenter.shared()
        center.togglePlayPauseCommand.addTarget { [weak self] _ in self?.toggle(); return .success }
        center.playCommand.addTarget { [weak self] _ in self?.resume(); return .success }
        center.pauseCommand.addTarget { [weak self] _ in self?.pause(); return .success }
        center.skipBackwardCommand.preferredIntervals = [30]
        center.skipForwardCommand.preferredIntervals = [30]
        center.skipBackwardCommand.addTarget { [weak self] _ in self?.skip(-30); return .success }
        center.skipForwardCommand.addTarget { [weak self] _ in self?.skip(30); return .success }
        avPlayer.volume = volume
        // Space toggles playback (the menu shows ⌘P), except while typing in a text field such as Search.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 49, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
                  self.book != nil, !Self.isTyping(NSApp.keyWindow?.firstResponder) else { return event }
            self.toggle()
            return nil
        }
    }

    var duration: TimeInterval { Double(book?.seconds ?? 0) }

    var currentChapter: Chapter? { book?.chapters.last { $0.start <= time } }

    func play(_ book: Book, url: URL) {
        if UserDefaults.standard.bool(forKey: Prefs.externalPlayer) {
            // Never hand a non-audio file (say a `.command` named in books.json) to Launch Services.
            guard ["m4b", "m4a", "mp3", "aax", "aaxc"].contains(url.pathExtension.lowercased()) else { return }
            return Prefs.open(url, appKey: Prefs.playerApp)
        }
        savePosition()
        self.book = book
        avPlayer.replaceCurrentItem(with: AVPlayerItem(url: url))
        let saved = UserDefaults.standard.double(forKey: Self.positionKey(book))
        seek(to: saved)
        resume()
    }

    func toggle() { isPlaying ? pause() : resume() }

    func resume() {
        guard book != nil else { return }
        avPlayer.rate = rate
        isPlaying = true
        updateNowPlaying()
    }

    func pause() {
        avPlayer.pause()
        isPlaying = false
        savePosition()
        updateNowPlaying()
    }

    func skip(_ seconds: TimeInterval) { seek(to: time + seconds) }

    /// Player ▸ Stop: saves the position and closes the player bar.
    func stop() {
        pause()
        avPlayer.replaceCurrentItem(with: nil)
        book = nil
        time = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    /// Text fields and web views (the Amazon sign-in page) keep their spaces.
    private static func isTyping(_ responder: NSResponder?) -> Bool {
        var view = responder as? NSView
        while let v = view {
            if v is NSText || v is WKWebView { return true }
            view = v.superview
        }
        return false
    }

    private var chapters: [Chapter] { book?.chapters ?? [] }
    func previousChapter() { ChapterNavigation.previous(from: time, in: chapters).map(seek(to:)) }
    func nextChapter() { ChapterNavigation.next(from: time, in: chapters).map(seek(to:)) }
    func chapterStart() { ChapterNavigation.bounds(at: time, in: chapters, duration: duration).map { seek(to: $0.lowerBound) } }
    /// One second before the chapter ends, so playback stays in it.
    func chapterEnd() {
        ChapterNavigation.bounds(at: time, in: chapters, duration: duration).map { seek(to: max($0.lowerBound, $0.upperBound - 1)) }
    }
    func changeVolume(by delta: Float) { volume = min(1, max(0, volume + delta)) }

    func seek(to seconds: TimeInterval) {
        let t = max(0, min(seconds, duration))
        time = t
        avPlayer.seek(to: CMTime(seconds: t, preferredTimescale: 600))
        updateNowPlaying()
    }

    private func tick(_ seconds: TimeInterval) {
        guard seconds.isFinite else { return }
        time = seconds
        if Int(seconds) % 15 == 0 { savePosition() }
    }

    private static func positionKey(_ b: Book) -> String { "position.\(b.id)" }

    private func savePosition() {
        if let book { UserDefaults.standard.set(time, forKey: Self.positionKey(book)) }
    }

    private func updateNowPlaying() {
        guard let book else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: book.title,
            MPMediaItemPropertyArtist: book.author,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: time,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(rate) : 0,
        ]
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }
}

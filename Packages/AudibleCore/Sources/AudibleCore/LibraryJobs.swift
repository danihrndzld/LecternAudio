import Foundation

/// Which books the library-wide actions apply to (Controls ▸ Download All From Audible,
/// Convert All to M4B). Pure so the app can both count them when the library changes and build the
/// work list when the menu item is chosen, from one rule.
public enum LibraryJobs {
    /// Books this account owns with no local file at all: no playable audio and no AAX waiting to be
    /// converted. The same rule as the sidebar's In Audible Only (`LibraryFilter.audibleOnly`).
    ///
    /// `owned` is the ASINs of the synced Audible catalog: a book only in the local folder cannot be
    /// downloaded, however little audio it has.
    public static func downloadable(_ books: [Book], owned: Set<String>) -> [Book] {
        books.filter { !$0.asin.isEmpty && !$0.hasEncrypted && !$0.hasAudio && owned.contains($0.asin) }
    }

    /// Books with an encrypted file and no playable audio that this account can activate, so the
    /// conversion never stops to ask for activation bytes. No file system checks, so the app can count
    /// them on every library change; Convert All drops books whose AAX is missing on disk or whose
    /// M4B already exists when it builds its run.
    public static func convertible(_ books: [Book], owned: Set<String>) -> [Book] {
        books.filter { $0.hasEncrypted && !$0.hasAudio && !$0.asin.isEmpty && owned.contains($0.asin) }
    }
}

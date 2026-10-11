# Earmark

A native macOS (SwiftUI) audiobook manager for your own Audible library, built to replace OpenAudible.

Status: v0.1 imports OpenAudible libraries, signs in to Audible, syncs the account's library and downloads/converts books to M4B. It includes a player (chapters, speed, Now Playing), MP3 export and local AAX conversion.

```sh
brew install xcodegen
xcodegen generate && open Earmark.xcodeproj
```

Development is agent-driven: see `CLAUDE.md`.

After signing in and syncing, choose **Download and Convert** on a book or open **Downloads** to queue all missing books. The queue resumes after relaunch and supports cancellation/retry. Enable **Download and convert new books after syncing** to automate subsequent syncs. Downloaded M4B files live in the account-specific Earmark Application Support folder and appear in the player automatically; **Show in Finder** reveals them. No OpenAudible folder is required.

For a local AAX file, **Conversion → Convert Selected Book to M4B…** uses the signed-in account when the book is in its synced library. Otherwise the manual activation field remains as an advanced import fallback. Local-import output still goes to `books/Earmark/` without rewriting OpenAudible's `books.json`. Originals are kept.

The first Xcode build downloads checksum-pinned FFmpeg 8.0 source and builds a minimal LGPL helper; later builds reuse the local cache. The app includes the helper, license, corresponding source archive and build script. No separate FFmpeg installation is needed. Sessions and registration cookies persist in Keychain; the sign-in web view itself remains ephemeral. See [conversion details and verification](docs/aax-conversion.md).

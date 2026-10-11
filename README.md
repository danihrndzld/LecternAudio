# Earmark

A native macOS (SwiftUI) audiobook manager for your own Audible library, built to replace OpenAudible.

Status: v0.1 opens an existing OpenAudible library folder (`books.json`) and shows it in a sidebar + table/cover grid + inspector UI with a built-in player (chapters, speed, Now Playing). It exports MP3 and converts local AAX files to M4B using FFmpeg. Audible sign-in, sync and download are tracked as issues.

```sh
brew install xcodegen
xcodegen generate && open Earmark.xcodeproj
```

Development is agent-driven: see `CLAUDE.md`.

To convert an AAX book, select it and choose **Conversion → Convert Selected Book to M4B…** (also available in the inspector and context menu). Enter the owning Audible account's eight-character activation bytes. Keys can be saved in Keychain per book. Earmark copies the audio without re-encoding, preserves chapters and cover art, and keeps the original AAX. Output goes to `books/Earmark/`; `earmark-conversions.json` records the result without rewriting OpenAudible's `books.json`.

The first Xcode build downloads checksum-pinned FFmpeg 8.0 source and builds a minimal LGPL helper; later builds reuse the local cache. The app includes the helper, license, corresponding source archive and build script. No separate FFmpeg installation is needed. AAXC and automatic activation-key retrieval are not implemented. See [conversion details and verification](docs/aax-conversion.md).

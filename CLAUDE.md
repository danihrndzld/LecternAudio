# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Lectern Audio (renamed from Earmark) is a native macOS SwiftUI app that manages the owner's own Audible library and replaces OpenAudible (Java/SWT). Feature inventory of the old app: `docs/openaudible-spec.md`. Stack decision: `docs/adr/0001-stack-and-workflow.md`. Lessons learned from past bugs, crashes and slowdowns: `docs/memory.md` (read it before touching the library UI, the build, or the workflows, and add to it when you learn something the hard way).

## Commands

Xcode 27.1 lives at a non-default path; most commands need it:
```sh
export DEVELOPER_DIR=/Applications/Xcode-27.1.0-Release.Candidate.app/Contents/Developer
```

Run all of these before pushing:
```sh
swift test --package-path Packages/AudibleCore
xcodegen generate                      # project.yml is the source of truth; LecternAudio.xcodeproj is generated and git-ignored
xcodebuild -scheme LecternAudio -destination platform=macOS -derivedDataPath build build
```
- One test: `swift test --package-path Packages/AudibleCore --filter <testFunctionName>` (Swift Testing `@Test` functions).
- The first app build compiles FFmpeg 8.0 and aria2 1.37.0 from checksum-pinned tarballs (`scripts/build-ffmpeg.sh`, `scripts/build-aria2.sh`, run as post-build scripts) and caches them under `build/`.
- Release locally: `scripts/release.sh <version> <build>` builds a universal app, signs it ad-hoc inside out, makes the DMG and ZIP, and writes `appcast.xml` signed with the Sparkle EdDSA key (from `SPARKLE_PRIVATE_KEY` or the login Keychain). CI does the same on `v*` tags (`.github/workflows/release.yml`).
- Running tests rewrites `Packages/AudibleCore/Package.resolved` with a Sparkle pin; don't commit that churn unless dependencies changed.

## Architecture

- `Packages/AudibleCore`: UI-free Swift package. It must build and test on Linux (CI job `core-linux`), so never import AppKit or SwiftUI; AVFoundation code (MP3Export, OggExport) sits behind `#if canImport(AVFoundation)`. It holds the models (`Book`, `Chapter`, `BookFile`), OpenAudible import (`OpenAudibleLibrary`), Audible sign-in, request signing and library sync (`AudibleAuth`, `AudibleLibrary`), the download job model and byte transport (`DownloadJob`, `ContentDownload`, `Aria2`), conversion (`AAXConversion`, `AudibleContent`), exports (`MP3Export`/`MP3Encoder`/`ID3Tag` on vendored LAME `CLAME`, `OggExport`/`VorbisEncoder` on vendored `COgg`/`CVorbis`, `LibraryExport` CSV/JSON/XLSX), and the library query cache `LibraryIndex`. Put pure logic here so it is unit-testable.
- `App/Sources`: SwiftUI app, MainActor by default. `@Observable` models created in `LecternAudioApp`:
  - `LibraryModel` merges the OpenAudible folder with the synced Audible list (`AudibleLibrary.merge`: Audible supplies list and metadata, the folder supplies files), owns security-scoped access to the folder and imports, and exposes the cached `LibraryIndex` (filtered and sorted books, sidebar counts, genres).
  - `AudibleSession` handles sign-in (WKWebView to Amazon, PKCE, device registration), Keychain storage and token refresh.
  - `DownloadModel` runs a serial persisted queue (licensing, downloading, converting); `ConversionModel` converts local AAX files. Both shell out to the bundled `ffmpeg` helper. Known queue bugs are tracked in issue #31.
  - `Player` wraps AVPlayer with chapters, Now Playing and saved positions.
  - `AppCommands` builds every menu; models are passed in explicitly. `SettingsView` holds `Prefs` keys and the settings panes.
- Bundled helpers live in `Contents/Helpers` (`ffmpeg`, `aria2c`) with `inherit` sandbox entitlements (`App/FFmpeg.entitlements`, `App/Aria2.entitlements`); run alone they crash at sandbox init, which is expected. aria2c gets the signed URL on stdin, never in argv.
- Sparkle 2 handles updates. The feed URL is the single build setting `LECTERN_FEED_URL` in `project.yml`. The app is ad-hoc signed (no Developer ID), so `com.apple.security.cs.disable-library-validation` is required for Sparkle.framework to load under the hardened runtime, and EdDSA is the only update trust path.

## Rules

- Target macOS 26. Do not use macOS 27-only API until GitHub's `macos-26` runner ships Xcode 27.
- Swift 6 strict concurrency. No `@unchecked Sendable` or `nonisolated(unsafe)` without a one-line reason.
- CI cannot log into Audible. Every network or crypto feature ships with offline tests: recorded JSON fixtures in `Tests/.../Fixtures`, known-answer crypto vectors. Fixtures never contain tokens, cookies, activation bytes, customer IDs or download links: redact them.
- Secrets (tokens, device keys, activation bytes) live in Keychain only. Never log them, and never log signed download URLs (aria2c output can contain them).
- Never send account headers to download CDNs or depend on OpenAudible's licensed key service. See `docs/aax-conversion.md`.
- Paths built from `books.json` or titles go through `OpenAudibleLibrary.url(for:)` (stays inside its folder) and `Book.fileName(_:fallback:)`. Only open files with an expected extension.
- Views inside `Table` rows and context menus must not read `@Environment` objects (they crashed: AppKit hosts them outside the window tree); pass dependencies in (see `Cover`, `BookActions`).
- Views shown/hidden inside a `NavigationSplitView` column (player bar, banners) must not raise the column's minimum width: give them `.frame(minWidth: 0, maxWidth: .infinity)`. A growing min size is applied mid constraint pass and crashes AppKit. Reproduce with `LECTERN_PLAY=1`.
- Never use `NSAttributedString` HTML import; use `HTMLText.markdown`.
- The sign-in window is only Amazon's page. Don't add native fields or overlays above it (the owner rejected that for Passwords AutoFill).
- `books/Earmark/` and `earmark-conversions.json` inside the user's OpenAudible folder keep the old name on purpose so earlier conversions are still found; do not rename them.
- Derive Audible auth/library API from open sources: mkb79/audible (MIT), audible-cli. Do not copy GPL code (Libation). Vendored C code keeps its license file and a README with version and SHA-256.
- Keep diffs small; one issue per PR. PR title = Conventional Commit (`feat:`, `fix:`, `chore:`…). It becomes the squash commit.

## Performance rules

The library is 500 to 1,000+ books. A sidebar switch must stay under about 100 ms of main-thread work; it used to freeze for 150 ms (see `docs/memory.md`).
- Never compute collections in `body`. Filtering, sorting, counts and grouping live in `LibraryIndex` (AudibleCore) and are recomputed only when books, filter, search or sort change. Read the cached result.
- Keep observation narrow. A view should read only the properties it renders; read fast-changing values (player time) only inside small leaf views like `PlayerBar`, never in `ContentView`.
- No disk or network work in `body` or per row: no `FileManager` calls, no `Data(contentsOf:)`, no date formatter creation. Resolve URLs when the library loads.
- Covers go through the shared ImageIO thumbnail cache in `Cover` (decoded off the main thread at display size, `NSCache`). Don't use `AsyncImage` for covers.
- Don't force table rebuilds with `.id(...)` on filter changes (measured 371 ms, worse than the 150 ms baseline).
- SwiftUI `Table` itself costs about 100 ms per full row update at 529 books (row diffing, row height measurement, row teardown). If a change needs more speed, the next step is an `NSTableView` behind `NSViewRepresentable`, in its own PR.
- Measure before and after any change to the library views with the perf harness below, using the real library size, and put the numbers in the PR body.

## Debugging and measuring

UI changes: render a snapshot and look at it. Debug builds read these environment variables:
```sh
xcodebuild -scheme LecternAudio -destination platform=macOS -derivedDataPath build build CODE_SIGN_ENTITLEMENTS= ENABLE_HARDENED_RUNTIME=NO   # unsandboxed debug (without the entitlements, hardened runtime refuses the ad-hoc Sparkle.framework)
open -g -n -W --env LECTERN_LIBRARY=<OpenAudible folder> --env LECTERN_SELECT=<asin> --env LECTERN_SNAPSHOT=/tmp/shot.png "build/Build/Products/Debug/Lectern Audio.app"
```
- The sidebar renders black in snapshots (vibrancy isn't captured by `cacheDisplay`); that is expected.
- `LECTERN_PLAY=1` plays the `LECTERN_SELECT` book. `LECTERN_SYNCED_LIBRARY=<library.json>` merges a synced Audible list without signing in.
- aria2c: a sandboxed Debug build with `--env LECTERN_ARIA2_TEST=<public https file> --stdout <file>` downloads it with aria2c, then URLSession only, and prints both durations.
- Always launch test builds with `open -g` so they don't take the owner's focus, and check `ls -t ~/Library/Logs/DiagnosticReports | head` after each launch so crash dialogs aren't left for the owner. Quit the processes you start.

Performance harness: `LECTERN_PERF_CYCLE=N` switches the sidebar Finished → All Books N times, prints main-thread ms per switch and body evaluations per view (`BodyCount.tick`), then quits; each switch is an "All Books" Points of Interest signpost for Instruments. `-viewMode YES` measures the cover grid. Measure optimized code with a separate bundle id:
```sh
xcodebuild -scheme LecternAudio -destination platform=macOS -derivedDataPath build/perf build CODE_SIGN_ENTITLEMENTS= ENABLE_HARDENED_RUNTIME=NO SWIFT_OPTIMIZATION_LEVEL=-O SWIFT_COMPILATION_MODE=wholemodule PRODUCT_BUNDLE_IDENTIFIER=com.danihrndzld.lecternaudio.perf
open -g -n -W --stdout /tmp/perf.txt --env LECTERN_LIBRARY=<OpenAudible folder> --env LECTERN_SYNCED_LIBRARY=<library.json> --env LECTERN_PERF_CYCLE=10 "build/perf/Build/Products/Debug/Lectern Audio.app" --args -viewMode NO
```
`xcrun xctrace record --launch` resolves the app by name and can start the installed `/Applications/Lectern Audio.app` instead; record with `--all-processes` while your build runs. Run A/B comparisons alternately; other builds on the machine add noise.

## Workflow

Agents work in their own git worktree (`git worktree add ../Lectern-<topic> -b <branch> origin/main`) and never edit, stash, reset or build in the owner's main checkout. Issues labeled `agent` are implemented by `.github/workflows/claude.yml` (only the repo owner's label or comment triggers it). CI (`ci.yml`) runs on every PR. `automerge.yml` squash-merges the PR when CI is green on the exact head commit. Add the label `hold` to a PR to stop the merge. PRs that change files under `.github/` are never automerged; merge them by hand. Nobody reviews code, so the tests are the review. Issues labeled `feature-request` or `future` wait until the owner adds `agent`.

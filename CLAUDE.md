# Lectern Audio

Native macOS audiobook manager for a user's own Audible library; it replaces OpenAudible (Java/SWT).
Feature inventory of the old app: `docs/openaudible-spec.md`. Stack decision: `docs/adr/0001-stack-and-workflow.md`.

## Layout
- `Packages/AudibleCore`: UI-free Swift package (Foundation + apple/swift-crypto for SHA-256/RSA). Models, OpenAudible import, and later Audible API, download, decrypt. Must build on Linux (CI job `core-linux`), so never import AppKit/SwiftUI/AVFoundation here; wrap Apple-only code in `#if canImport(...)`.
- `App/Sources`: SwiftUI app, MainActor by default. `project.yml` is the source of truth; `LecternAudio.xcodeproj` is generated and git-ignored.

## Rules
- Target macOS 26. Do not use macOS 27-only API until GitHub's `macos-26` runner ships Xcode 27.
- Swift 6 strict concurrency. No `@unchecked Sendable` or `nonisolated(unsafe)` without a one-line reason.
- CI cannot log into Audible. Every network or crypto feature ships with offline tests: recorded JSON fixtures in `Tests/.../Fixtures`, known-answer crypto vectors. Fixtures never contain tokens, cookies, activation bytes, customer IDs or download links: redact them.
- Secrets (tokens, device keys, activation bytes) live in Keychain only. Never log them.
- Views inside `Table` rows and context menus must not read `@Environment` objects (they crashed: AppKit hosts them outside the window tree); pass dependencies in (see `Cover`, `BookActions`).
- Views shown/hidden inside a `NavigationSplitView` column (player bar, banners) must not raise the column's minimum width: give them `.frame(minWidth: 0, maxWidth: .infinity)`. A growing min size is applied mid constraint pass and crashes AppKit. Reproduce with `LECTERN_PLAY=1` (plays the `LECTERN_SELECT` book).
- The app was renamed from Earmark. `books/Earmark/` and `earmark-conversions.json` inside the user's OpenAudible folder keep the old name on purpose so earlier conversions are still found; do not rename them.
- Never use `NSAttributedString` HTML import; use `HTMLText.markdown`.
- AAX/AAXC → M4B conversion uses bundled LGPL FFmpeg. Signed-in accounts supply AAX activation data or AAXC licenses automatically; manual activation is a local-import fallback. Tokens, website cookies and cached activation data stay in Keychain; per-content credentials stay in memory. Never send account headers to download CDNs or depend on OpenAudible's licensed key service. See `docs/aax-conversion.md`.
- Derive Audible auth/library API from open sources: mkb79/audible (MIT), audible-cli. Do not copy GPL code (Libation).
- Keep diffs small; one issue per PR. PR title = Conventional Commit (`feat:`, `fix:`, `chore:`…). It becomes the squash commit.

## Verify before pushing (run all)
```sh
swift test --package-path Packages/AudibleCore
xcodegen generate
xcodebuild -scheme LecternAudio -destination platform=macOS -derivedDataPath build build
```
UI changes: render a snapshot and look at it. Debug builds read these env vars:
```sh
xcodebuild -scheme LecternAudio -destination platform=macOS -derivedDataPath build build CODE_SIGN_ENTITLEMENTS=   # unsandboxed debug
open -n -W --env LECTERN_LIBRARY=<OpenAudible folder> --env LECTERN_SELECT=<asin> --env LECTERN_SNAPSHOT=/tmp/shot.png "build/Build/Products/Debug/Lectern Audio.app"
```
The sidebar renders black in snapshots (vibrancy isn't captured by `cacheDisplay`); that is expected.

## Workflow
Issues labeled `agent` are implemented by `.github/workflows/claude.yml`. CI (`ci.yml`) runs on every PR. `automerge.yml` squash-merges the PR when CI is green. Add the label `hold` to a PR to stop the merge. PRs that change files under `.github/` are never automerged; merge them by hand. Nobody reviews code, so the tests are the review.

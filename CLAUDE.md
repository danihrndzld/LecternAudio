# Earmark

Native macOS audiobook manager for a user's own Audible library; it replaces OpenAudible (Java/SWT).
Feature inventory of the old app: `docs/openaudible-spec.md`. Stack decision: `docs/adr/0001-stack-and-workflow.md`.

## Layout
- `Packages/AudibleCore`: UI-free Swift package (Foundation only). Models, OpenAudible import, and later Audible API, download, decrypt. Must build on Linux (CI job `core-linux`), so never import AppKit/SwiftUI/AVFoundation here; wrap Apple-only code in `#if canImport(...)`.
- `App/Sources`: SwiftUI app, MainActor by default. `project.yml` is the source of truth; `Earmark.xcodeproj` is generated and git-ignored.

## Rules
- Target macOS 26. Do not use macOS 27-only API until GitHub's `macos-26` runner ships Xcode 27.
- Swift 6 strict concurrency. No `@unchecked Sendable` or `nonisolated(unsafe)` without a one-line reason.
- CI cannot log into Audible. Every network or crypto feature ships with offline tests: recorded JSON fixtures in `Tests/.../Fixtures`, known-answer crypto vectors. Fixtures never contain tokens, cookies, activation bytes, customer IDs or download links: redact them.
- Secrets (tokens, device keys, activation bytes) live in Keychain only. Never log them.
- Views inside `Table` rows and context menus must not read `@Environment` objects (they crashed: AppKit hosts them outside the window tree); pass dependencies in (see `Cover`, `BookActions`).
- Never use `NSAttributedString` HTML import; use `HTMLText.markdown`.
- Derive Audible auth/API/decrypt from open sources: mkb79/audible (MIT), audible-cli, FFmpeg's LGPL `aax` demuxer. Do not copy GPL code (AAXClean, Libation).
- Keep diffs small; one issue per PR. PR title = Conventional Commit (`feat:`, `fix:`, `chore:`…). It becomes the squash commit.

## Verify before pushing (run all)
```sh
swift test --package-path Packages/AudibleCore
xcodegen generate
xcodebuild -scheme Earmark -destination platform=macOS -derivedDataPath build build
```
UI changes: render a snapshot and look at it. Debug builds read these env vars:
```sh
xcodebuild -scheme Earmark -destination platform=macOS -derivedDataPath build build CODE_SIGN_ENTITLEMENTS=   # unsandboxed debug
open -n -W --env EARMARK_LIBRARY=<OpenAudible folder> --env EARMARK_SELECT=<asin> --env EARMARK_SNAPSHOT=/tmp/shot.png build/Build/Products/Debug/Earmark.app
```
The sidebar renders black in snapshots (vibrancy isn't captured by `cacheDisplay`); that is expected.

## Workflow
Issues labeled `agent` are implemented by `.github/workflows/claude.yml`. CI (`ci.yml`) runs on every PR. `automerge.yml` squash-merges the PR when CI is green. Add the label `hold` to a PR to stop the merge. Nobody reviews code, so the tests are the review.

# ADR 0001: Native SwiftUI + Swift core package; CI-gated automerge

Status: accepted 2026-10-11. The memo below was written by an advisor model (Fable). These deviations apply:

- The repo is **private** (owner's request). Rulesets and merge queue need a paid plan on private repos, so the merge gate is `automerge.yml`: it runs on `workflow_run` of CI and squash-merges only when all CI jobs pass on the PR's head SHA. This works on any plan.
- No release, notarization or Sparkle pipeline yet: the only signing identity available is Apple Development (no Developer ID). Add it when a Developer ID exists.
- GRDB is deferred until Earmark owns its own library store (sync issue). v0.1 reads OpenAudible's `books.json` directly.
- macOS CI minutes are billed on private repos; the core suite also runs on Linux to keep feedback cheap.
- DRM is out of scope (amended 2026-10-11): no activation-bytes recovery, voucher decryption or AAX/AAXC decryption. The memo's decrypt section below is superseded. Earmark manages, plays and exports already-decrypted files.

---

# OpenAudible rebuild: decision memo (2026-10-11)

## 1. Stack: native Swift; no Tauri, no Rust core

Decision: SwiftUI app (deployment target macOS 26) + UI-free SwiftPM package `AudibleCore` (Foundation, GRDB, CommonCrypto). CI builds with Xcode 26.6 / Swift 6.3 until hosted runners get Xcode 27 (the `xcode-27` preview image of 2026-10-06 carries only 27.2 betas: https://github.com/actions/runner-images/releases).

Tauri 2.12.3 renders in WKWebView: no `Table`, no `NavigationSplitView` sidebar, no toolbar Liquid Glass; `window-vibrancy`'s `apply_liquid_glass` needs `macOSPrivateApi: true` (https://github.com/tauri-apps/window-vibrancy). Native looks is criterion #1; a web view fails it.

Rust + UniFFI: docs state "partial support for Swift 6" and generated async code is not `Sendable` (issue #2448, https://mozilla.github.io/uniffi-rs/latest/swift/overview.html); two toolchains double CI and agent context. Portability survives: `AudibleCore` imports no AppKit, builds on `ubuntu-latest` at 1x minutes, reusable by a GTK/Windows shell.

Decrypt without ffmpeg: AAX is AES-128-CBC per sample, key derived from 4 activation bytes, fixed key `77214d4b196a87cd520045fd20a51d67`, a SHA-1 chain and the `adrm` atom, per the LGPL FFmpeg patch https://ffmpeg.org/pipermail/ffmpeg-devel/2015-July/175659.html; AAXC takes key+iv from the voucher. Port that patch, never GPL-3 AAXClean. `CCCrypt` under `#if canImport(CommonCrypto)`; the Linux path (swift-crypto `_CryptoExtras.AES._CBC`, verify no-padding) stays off until confirmed. Output is lossless M4B: AVFoundation plays it with chapters, feeds `MPNowPlayingInfoCenter`, CoreSpotlight indexes it. AVFoundation cannot encode MP3, so MP3 leaves v1 (`libmp3lame.dylib`, LGPL, if asked).

Audible API: `POST https://api.amazon.{domain}/auth/register`, device_type `A2CZJZGLK2JJVM`; `POST /1.0/content/{asin}/licenserequest` with `consumption_type: Download`, `supported_drm_types: [Mpeg, Adrm]`; voucher = AES-CBC, key = SHA-256(device_type+device_serial+customer_id+asin)[0:16], iv = [16:]. Sources: https://raw.githubusercontent.com/mkb79/Audible/master/src/audible/register.py, `.../login.py` (PKCE URL, OTP/CVF), `.../aescipher.py`, https://raw.githubusercontent.com/mkb79/audible-cli/master/src/audible_cli/models.py.

## 2. Agentic git workflow

Repo: public, under a free GitHub org. Standard macOS runners are free on public repos; private pays $0.062/min, so Free's 2,000 minutes buy ~200 macOS minutes/month (https://docs.github.com/en/billing/managing-billing-for-your-products/about-billing-for-github-actions). Rulesets on private repos need Pro, $4/month (https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/about-rulesets); merge queue exists only for org-owned public repos or Enterprise Cloud (https://docs.github.com/en/pull-requests/how-tos/merge-and-close-pull-requests/merging-a-pull-request-with-a-merge-queue). Private fallback: Pro + self-hosted `actions/runner` on the dev Mac, no merge queue.

Settings: Allow auto-merge; squash only, message = PR title; auto-delete branches; allow Actions to create PRs. Ruleset on `main`: require PR, required checks `CI / macOS`, `CI / core-linux`, `CI / pr-title`, `CI / claude-review`, require merge queue, block force-push, zero required reviews, because Claude "cannot approve pull requests" (https://github.com/anthropics/claude-code-action/blob/main/docs/capabilities-and-limitations.md).

Tokens: custom GitHub App (Contents/Issues/PRs read-write) via `actions/create-github-app-token@v1`, passed as `github_token` to claude-code-action and `token` to release-please. GITHUB_TOKEN-created pushes and PRs never trigger CI.

Workflows in `.github/workflows/`:
- `ci.yml` (pull_request, merge_group): job `macOS` on `macos-26`: `sudo xcode-select -s /Applications/Xcode_26.6.app`, `xcodegen generate`, `xcodebuild test -scheme OpenAudible -destination platform=macOS`; job `core-linux`: `swift test --package-path Packages/AudibleCore`; jobs `pr-title` (`amannn/action-semantic-pull-request`, squash commit = PR title) and `claude-review` (docs/solutions.md prompt, `additional_permissions: actions: read`, fails on verdict `block`) with `if: github.event_name == 'pull_request'` (skipped = success in the queue).
- `claude-issue.yml` (issues labeled `claude`): `runs-on: macos-26`, `anthropics/claude-code-action@v1`, `claude_code_oauth_token` (`claude setup-token`); prompt: implement, test, `git checkout -b claude/<issue>`, push, `gh pr create`, `gh pr merge --auto --squash --delete-branch`; `claude_args: --allowedTools "Edit,Read,Write,Bash(git:*),Bash(gh pr:*),Bash(xcodebuild:*),Bash(swift:*)" --max-turns 60`. By default Claude only "links to a prefilled PR creation page".
- `automerge.yml` (`pull_request_target` opened; author `dependabot[bot]` or `<app>[bot]`): `gh pr merge --auto --squash --delete-branch` with `GH_TOKEN` = App token, so the merge push triggers `release-please.yml` (https://cli.github.com/manual/gh_pr_merge).
- `release-please.yml` (`schedule` weekly Monday + `workflow_dispatch`): `googleapis/release-please-action@v4`, `release-type: simple` writes `version.txt` + `CHANGELOG.md`; `project.yml` reads it into `MARKETING_VERSION`; `CURRENT_PROJECT_VERSION = github.run_number` (Sparkle needs numeric builds).
- `release.yml` (release published): `apple-actions/import-codesign-certs`, `xcodebuild archive`, `xcrun notarytool submit OpenAudible.zip --key --key-id --issuer --wait`, `xcrun stapler staple`, Sparkle `generate_appcast` (ed25519 secret), upload asset, commit `appcast.xml` to `gh-pages`.
- `dependabot.yml`: `swift`, `github-actions`, weekly.

UI verification: swift-snapshot-testing 1.19.6 (Swift Testing attachments, macOS 27 fix; https://github.com/pointfreeco/swift-snapshot-testing/releases). Render through `NSHostingView.cacheDisplay(in:to:)`, not an `NSWindow` (title-bar height differs on headless VMs); record references on the pinned `macos-26` image; upload diffs as artifacts. Plus one XCUITest smoke test.

## 3. Layout and macOS practices

```
project.yml      # xcodegen; SWIFT_VERSION 6; App: SWIFT_DEFAULT_ACTOR_ISOLATION MainActor, SWIFT_APPROACHABLE_CONCURRENCY YES
App/{OpenAudibleApp.swift, Features/{Library,Detail,Player,Settings}, Tests, UITests}
Packages/AudibleCore/{Sources/{AudibleAuth,AudibleAPI,AAXDecrypt,Library,Download}, Tests}
OpenAudible.entitlements  CLAUDE.md  version.txt  release-please-config.json
```

- Storage: GRDB 7.11.1 (Swift 6.1+, FTS5, Linux; https://github.com/groue/GRDB.swift/releases), not SwiftData (no Linux, no headless migration tests).
- Tokens: one JSON blob (adp_token, device_private_key, refresh_token) in Keychain via `SecItemAdd`.
- Sandbox + hardened runtime: entitlements `app-sandbox`, `network.client`, `files.user-selected.read-write`, `files.bookmarks.app-scope`. Sparkle 2.10.0 needs `SUEnableInstallerLauncherService = YES` and mach-lookup exceptions `$(PRODUCT_BUNDLE_IDENTIFIER)-spks` / `-spki` (https://sparkle-project.org/documentation/sandboxing/).
- `CLAUDE.md`: "target macOS 26; no macOS-27-only API until runners ship Xcode 27".

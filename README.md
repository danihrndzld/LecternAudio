# Lectern Audio

Lectern Audio is a native macOS app for managing the audiobooks in your own Audible library, and it replaces OpenAudible, which is a Java app. Lectern Audio is written in Swift and SwiftUI, so it uses the standard macOS sidebar, table, inspector, menus, and Now Playing controls.

Lectern Audio is for personal use with books you bought, and it isn't affiliated with Audible or Amazon. The app was called Earmark before it was renamed to Lectern Audio.

## What the app does

You can browse your library in a sortable table or in a grid of covers, and you can filter it from the sidebar by status, file type, or genre. The inspector on the right shows the cover, the details, the summary, and the chapter list of the selected book.

The main features are listed below.

- Library
  - Open an existing OpenAudible folder and read its `books.json`.
  - Sign in to Audible and sync the list of books in your account, including books you haven't downloaded yet.
- Listening
  - Play M4B and MP3 files with chapters, playback speed, and saved positions.
  - Control playback from the Player menu, the keyboard, and the macOS Now Playing widget. The Player menu has shortcuts for skipping, chapters, and volume.
- Files
  - Download books from your account and convert them to M4B.
  - Export a book to MP3, as one file or as one file per chapter, with ID3 tags, chapters, and cover art. MP3 files use 320 kbps by default.
  - Export a book to Ogg Vorbis at the highest quality, as one file or as one file per chapter. The file keeps the title, author, narrator, chapters, and cover art.
  - Import your own M4B and MP3 files, and join several audio files into one M4B.
  - Export the library list to Excel, CSV, or JSON, and export a poster of the covers as a PNG image.
- Settings
  - Choose the output format (M4B, MP3, or Ogg Vorbis), the MP3 bitrate, the Ogg Vorbis quality, automatic sync, appearance, table font size, and external apps.

The Help menu can check for updates, open a bug report with your app and macOS versions filled in, and show a diagnostics window with library counts that you can copy.

## Install

Lectern Audio isn't signed with an Apple Developer ID, so macOS asks you to confirm it once.

1. Download the latest `LecternAudio` DMG file from the [Releases](https://github.com/danihrndzld/LecternAudio/releases) page.
2. Open the DMG and drag Lectern Audio to the Applications folder.
3. Open Lectern Audio. macOS 26 says it can't verify the app, so click Done.
4. Open System Settings, go to Privacy & Security, scroll to the Security section, and click Open Anyway next to the Lectern Audio message. Then confirm with your password.

If you prefer the Terminal, this command removes the download flag instead, and Lectern Audio then opens normally.

```sh
xattr -dr com.apple.quarantine "/Applications/Lectern Audio.app"
```

You only do this once. Lectern Audio checks for new versions once a day with Sparkle, and you can also choose Help, then Check for Updates. When a new version is out, Sparkle shows it with an Install Update button, checks it against Lectern Audio's signing key, and relaunches the app. macOS doesn't ask you to approve the updated app again. You can turn off the daily check in Settings.

If you used the app when it was called Earmark, macOS treats Lectern Audio as a new app, so you set it up again once. Choose your OpenAudible folder again, sign in to Audible again, and set your preferences in Settings again. Books that Earmark already converted stay in your OpenAudible folder, and Lectern Audio finds them.

## Requirements

You need macOS 26 or later to run Lectern Audio. To build it, you need Xcode 26 or later and XcodeGen, which you can install with Homebrew.

The first build downloads the FFmpeg 8.0 source code, checks its checksum, and builds a small FFmpeg helper that the app uses for conversion. Later builds reuse the cached helper, so you don't need to install FFmpeg yourself.

## Build and run

Run the following commands from the repository folder.

```sh
brew install xcodegen
xcodegen generate
open LecternAudio.xcodeproj
```

Then build and run the `LecternAudio` scheme in Xcode. The project file is generated from `project.yml`, and Git ignores it, so run `xcodegen generate` again after you pull changes.

## First use

When you open Lectern Audio for the first time, you can start from an OpenAudible folder, from your Audible account, or from both.

1. To use an OpenAudible library, choose File, then Open OpenAudible Library, and select the folder that contains `books.json`. Lectern Audio reads the folder and doesn't change OpenAudible's files.
2. To use your Audible account, open Settings, go to the Account tab, and choose Sign In to Audible. Amazon's sign in page opens inside Lectern Audio, and it handles the captcha and two factor codes itself.
3. After you sign in, click the sync button in the toolbar to fetch your library. Books that exist only in your account appear under "In Audible Only" in the sidebar.

Lectern Audio keeps your account tokens in the macOS Keychain. When you sign out, Lectern Audio removes the device from your Amazon account and deletes the saved tokens and the synced library file.

More details about downloads and conversion are in [docs/aax-conversion.md](docs/aax-conversion.md).

## Project layout

The code is split into a Swift package and an app target, so the core logic can be tested without a user interface.

- `Packages/AudibleCore` holds the models, the OpenAudible import, the Audible sign in and library API, the MP3 and Ogg Vorbis encoders, and their tests. It builds on Linux as well as macOS, so it doesn't import AppKit or SwiftUI.
- `App/Sources` holds the SwiftUI app, including the windows, the player, the settings, and the download queue.
- `docs` holds the feature inventory of OpenAudible, the design decision record, and the conversion notes.
- `scripts/build-ffmpeg.sh` builds the bundled FFmpeg helper.

## Tests

Run the package tests and a full app build with the commands below. CI runs the same steps on every pull request, on Linux for the package and on macOS for the app.

```sh
swift test --package-path Packages/AudibleCore
xcodegen generate
xcodebuild -scheme LecternAudio -destination platform=macOS -derivedDataPath build build
```

The tests run offline, because CI can't sign in to Audible. Network code is tested against recorded responses with personal data removed.

## How development works

AI coding agents write most of the code, and pull requests merge without a human code review. The tests and the CI checks act as the review, so every change has to pass them before it lands.

1. First, an agent works on a branch and opens a pull request with a Conventional Commit title, e.g., `feat: app icon`.
2. Second, the CI workflow builds the app and runs the tests.
3. Third, when CI passes, the automerge workflow squash merges the pull request into `main`.

You can stop an automatic merge by adding the `hold` label to a pull request. Issues with the `agent` label can be picked up by the Claude GitHub workflow, which needs the Claude GitHub App to be installed on the repository. The rules that agents follow are in `CLAUDE.md`.

## Releasing

To publish a version, push a tag that starts with `v`.

```sh
git tag v0.2.0 && git push origin v0.2.0
```

The release workflow builds a universal app, packs it as a DMG and a ZIP, signs the ZIP for Sparkle with the `SPARKLE_PRIVATE_KEY` secret, and publishes a GitHub release with the DMG, the ZIP and `appcast.xml`. The tag sets the version, and the workflow run number sets the build number. Run `scripts/release.sh 0.2.0 1` to build the same files on your Mac; it signs with the Sparkle key in your login Keychain. The feed address is the `LECTERN_FEED_URL` setting in `project.yml`.

Sparkle reads the feed without signing in to GitHub, so updates only reach people when the repository is public.

## Licenses

Lectern Audio bundles third party code under the licenses listed below.

- LAME 3.100 for MP3 encoding, under the LGPL.
- libogg 1.3.6 and libvorbis 1.3.7 for Ogg Vorbis encoding, under the BSD 3 clause license.
- FFmpeg 8.0 for conversion, under the LGPL 2.1. The app includes the license, the matching source archive, and the build script.
- swift-crypto for SHA-256 and RSA, under the Apache License 2.0.
- Sparkle 2.10.0 for updates, under the MIT License.

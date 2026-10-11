# Earmark

Earmark is a native macOS app for managing the audiobooks in your own Audible library, and it replaces OpenAudible, which is a Java app. Earmark is written in Swift and SwiftUI, so it uses the standard macOS sidebar, table, inspector, menus, and Now Playing controls.

Earmark is for personal use with books you bought, and it isn't affiliated with Audible or Amazon.

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
  - Export a book to MP3, as one file or as one file per chapter, with ID3 tags, chapters, and cover art.
  - Import your own M4B and MP3 files, and join several audio files into one M4B.
  - Export the library list to Excel, CSV, or JSON, and export a poster of the covers as a PNG image.
- Settings
  - Choose the output format, the MP3 bitrate, automatic sync, appearance, table font size, and external apps.

The Help menu can check GitHub for new releases, open a bug report with your app and macOS versions filled in, and show a diagnostics window with library counts that you can copy.

## Requirements

You need macOS 26 or later to run Earmark. To build it, you need Xcode 26 or later and XcodeGen, which you can install with Homebrew.

The first build downloads the FFmpeg 8.0 source code, checks its checksum, and builds a small FFmpeg helper that the app uses for conversion. Later builds reuse the cached helper, so you don't need to install FFmpeg yourself.

## Build and run

Run the following commands from the repository folder.

```sh
brew install xcodegen
xcodegen generate
open Earmark.xcodeproj
```

Then build and run the `Earmark` scheme in Xcode. The project file is generated from `project.yml`, and Git ignores it, so run `xcodegen generate` again after you pull changes.

## First use

When you open Earmark for the first time, you can start from an OpenAudible folder, from your Audible account, or from both.

1. To use an OpenAudible library, choose File, then Open OpenAudible Library, and select the folder that contains `books.json`. Earmark reads the folder and doesn't change OpenAudible's files.
2. To use your Audible account, open Settings, go to the Account tab, and choose Sign In to Audible. Amazon's sign in page opens inside Earmark, and it handles the captcha and two factor codes itself.
3. After you sign in, click the sync button in the toolbar to fetch your library. Books that exist only in your account appear under "In Audible Only" in the sidebar.

Earmark keeps your account tokens in the macOS Keychain. When you sign out, Earmark removes the device from your Amazon account and deletes the saved tokens and the synced library file.

More details about downloads and conversion are in [docs/aax-conversion.md](docs/aax-conversion.md).

## Project layout

The code is split into a Swift package and an app target, so the core logic can be tested without a user interface.

- `Packages/AudibleCore` holds the models, the OpenAudible import, the Audible sign in and library API, the MP3 encoder, and their tests. It builds on Linux as well as macOS, so it doesn't import AppKit or SwiftUI.
- `App/Sources` holds the SwiftUI app, including the windows, the player, the settings, and the download queue.
- `docs` holds the feature inventory of OpenAudible, the design decision record, and the conversion notes.
- `scripts/build-ffmpeg.sh` builds the bundled FFmpeg helper.

## Tests

Run the package tests and a full app build with the commands below. CI runs the same steps on every pull request, on Linux for the package and on macOS for the app.

```sh
swift test --package-path Packages/AudibleCore
xcodegen generate
xcodebuild -scheme Earmark -destination platform=macOS -derivedDataPath build build
```

The tests run offline, because CI can't sign in to Audible. Network code is tested against recorded responses with personal data removed.

## How development works

AI coding agents write most of the code, and pull requests merge without a human code review. The tests and the CI checks act as the review, so every change has to pass them before it lands.

1. First, an agent works on a branch and opens a pull request with a Conventional Commit title, e.g., `feat: app icon`.
2. Second, the CI workflow builds the app and runs the tests.
3. Third, when CI passes, the automerge workflow squash merges the pull request into `main`.

You can stop an automatic merge by adding the `hold` label to a pull request. Issues with the `agent` label can be picked up by the Claude GitHub workflow, which needs the Claude GitHub App to be installed on the repository. The rules that agents follow are in `CLAUDE.md`.

## Licenses

Earmark bundles third party code under the licenses listed below.

- LAME 3.100 for MP3 encoding, under the LGPL.
- FFmpeg 8.0 for conversion, under the LGPL 2.1. The app includes the license, the matching source archive, and the build script.
- swift-crypto for SHA-256 and RSA, under the Apache License 2.0.

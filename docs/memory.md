# Lessons learned

This file records what went wrong while building Lectern Audio, why it happened, and the rule that now prevents it. Agents add an entry when they learn something the hard way, with the PR or issue number. The short rules also live in `CLAUDE.md`, and this file keeps the reasons.

## Performance

### Switching to All Books froze the window (PR #41)

The owner reported heavy lag when clicking All Books. The library has 529 books when the OpenAudible folder (518) and the synced Audible list (513) are merged. Each switch cost 133 to 157 ms of main-thread work in the list and 61 to 75 ms in the cover grid.

The Time Profiler trace showed several causes in app code, and they added up to about 30 ms per switch.

- The filtered and sorted list was rebuilt three times per switch, because the table, the window subtitle and the File menu each called a computed property. That took 12.4 ms, plus about 9 ms of `Book` struct copies during sorting.
- Each table row looked up its thumbnail with `FileManager.fileExists`, which took about 3 ms per switch, and OpenAudible's `thumb/` folder was empty anyway.
- `ContentView`, the File menu and the genre list re-ran their bodies on every switch because they read more model properties than they render.

The fix moved filtering, sorting, sidebar counts and genres into `LibraryIndex` in AudibleCore, which recomputes only when its inputs change. Covers now use an ImageIO thumbnail decoded off the main thread at display size, kept in an `NSCache`. App code now costs about 11 ms per switch, the list takes 101 to 117 ms and the grid 45 to 52 ms.

The rest of the cost is inside SwiftUI `Table`. Row diffing takes 39 to 51 ms, row height measurement 28 to 38 ms, and teardown of old row views about 25 ms. App code can't remove that, so a faster list needs an `NSTableView` behind `NSViewRepresentable`.

What did not help:
- Recreating the table with `.id(model.filter)` made a switch take 371 ms.
- Turning off table animations and removing tooltips changed nothing.
- Date formatting, image decoding and the player's once a second time update never showed up on the main thread.

How to avoid a repeat:
- Measure with the real library size, not a three book fixture. The cost scales with the number of rows and with the window height.
- Use the `LECTERN_PERF_CYCLE` harness from `CLAUDE.md` before and after a change, run baseline and fix alternately, and note the machine load, because other builds running at the same time added noise of up to 30%.
- Count body evaluations with `BodyCount.tick`, because the SwiftUI Instruments template recorded no view updates in this setup.

## Crashes

### Environment objects in table cells (first build)

The app crashed at launch with "No Observable object of type LibraryModel found". AppKit hosts `Table` cells and context menus outside the window's view tree, so they don't inherit `.environment` objects. Pass models into those views as parameters.

### Playing a book crashed the window (PR #23)

When the player bar appeared, it raised the detail column's minimum width. `NSSplitView` applied the new minimum during the constraint pass, and AppKit threw "needs update constraints". The first fix attempt, which moved the bar from a safe area inset into a `VStack`, did not help. A bisection showed that the speed `Picker` gave the bar a large fixed width. The fix is `.frame(minWidth: 0, maxWidth: .infinity)` on any view that appears or disappears inside a split view column. `LECTERN_PLAY=1` reproduces it without clicks.

### Summary HTML crashed a system helper (PR #9)

`NSAttributedString` HTML import runs WebKit in `nsattributedstringagent`, which faulted under the sandbox. Use `HTMLText.markdown` for Audible summaries.

### Debug builds crashed at launch after Sparkle was added

An unsandboxed Debug build made with `CODE_SIGN_ENTITLEMENTS=` also dropped `disable-library-validation`, so the hardened runtime refused the ad-hoc signed Sparkle.framework. The owner saw crash dialogs from an agent's build. Build unsandboxed apps with `ENABLE_HARDENED_RUNTIME=NO`, launch them with `open -g`, and check `~/Library/Logs/DiagnosticReports` after each launch.

## Build, signing and release

- The app is ad-hoc signed, so Release builds need `com.apple.security.cs.disable-library-validation` to load Sparkle.framework, and Sparkle trusts updates through the EdDSA signature only. A Sparkle installed update has no quarantine attribute and launches without a Gatekeeper prompt, but the first manual install needs Open Anyway or `xattr -dr com.apple.quarantine`.
- Bundled helpers (`ffmpeg`, `aria2c`) carry `app-sandbox` and `inherit` entitlements and must be signed inside out before the app. Run alone, they exit at sandbox init with SIGTRAP, which is expected.
- While the repository is private, `releases/latest/download/appcast.xml` returns 404 to the app, so updates reach nobody.
- Renaming the bundle ID gives the app a new sandbox container, so the folder choice, settings and the Audible sign-in must be set up again. Files the app wrote into the user's OpenAudible folder keep their old names (`books/Earmark/`, `earmark-conversions.json`) so they are still found.
- After the rename, a stale generated `Earmark.xcodeproj` made `xcodebuild` refuse to run. Delete old generated projects.

## Workflows and agents

- `gh pr diff` fails with HTTP 406 when a diff is over 20,000 lines, which happens when C libraries are vendored. Automerge now lists PR files through the paginated REST API (PR #36). `gh pr view --json files` is not a replacement, because it returns only the first 100 files.
- Automerge pins the merge to the commit CI tested with `--match-head-commit`, and it skips PRs that touch `.github/` so an agent cannot weaken its own checks (PR #30).
- `xcrun xctrace record --launch` resolved the app by name and started the installed copy in `/Applications` instead of the agent's build, and those stray copies kept running. Record with `--all-processes`, and quit every process you start.
- Agents must work in their own worktree. The owner's checkout once held important uncommitted work, and another session edited it live.
- Running `swift test` rewrites `Package.resolved` with a Sparkle pin. Don't commit that change by accident.
- The CI runner uses Xcode 26, which failed to compile a large `ContentView` body that Xcode 27 compiled (PR #26). The log was cut off, so the cause is probably type checking time. Splitting the body into helper functions fixed it, so keep view bodies small.

## Scope decisions by the owner

- The sign-in window stays a plain Amazon web page. Native email, password and code fields above it, added for Passwords AutoFill, were rejected.
- Web Server, Transcribe, the command line tool, Linux and Windows are `future` issues (#19, #20, #38, #39, #40).

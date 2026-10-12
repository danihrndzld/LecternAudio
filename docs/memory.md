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

The rest of the cost was inside SwiftUI `Table`, and this entry's "101 to 117 ms" understated it badly: the harness lost the span whenever the table update ran inside a nested run loop, and the one transition it measured (Finished → All Books on the merged library) happened to be a cheap one. The next entry has the real numbers (3 to 9 s) and the `NSTableView` that replaced the `Table`.

What did not help:
- Recreating the table with `.id(model.filter)` (371 ms then; 243 to 360 ms per switch when remeasured in PR #43).
- Turning off table animations and removing tooltips changed nothing.
- Date formatting, image decoding and the player's once a second time update never showed up on the main thread.

How to avoid a repeat:
- Measure with the real library size, not a three book fixture. The cost scales with the number of rows and with the window height.
- Use the `LECTERN_PERF_CYCLE` harness from `CLAUDE.md` before and after a change, run baseline and fix alternately, and note the machine load, because other builds running at the same time added noise of up to 30%.
- Count body evaluations with `BodyCount.tick`, because the SwiftUI Instruments template recorded no view updates in this setup.

### In Audible Only → All Books froze the window for 5 s (PR #43)

The owner reported the freeze with the Release build of PR #41 installed, signed out, with only the OpenAudible folder open (518 books, 144 of them without local files). PR #41 had measured Finished → All Books at 110 to 150 ms and did not see it.

Reproduced with the owner's `books.json` and `art/` in an optimized build (`sample` call trees and an xctrace Time Profiler trace agree):
- Finished → All Books 9.1 s, History → All Books 8.2 s (8.0 s on the merged library), In Audible Only → All Books 3.2 s. Downloaded → All Books 71 ms, Not Converted → All Books 157 ms. The reverse switches took 160 to 195 ms.
- All of it was inside `AppKitOutlineTableCoordinator.update(…diffRows…)` → `-[NSTableView endUpdates]` → `_doAutomaticRowHeightsForInsertedAndVisibleRows`: SwiftUI `Table` diffs the old and new rows and inserts the new ones, and AppKit, to keep the top visible row stable, builds a full hosted row view (`NSHostingView`, Auto Layout, the `Cover` view) for every inserted row above it to measure its automatic height, then tears each one down (`_removeViewAndAddToReuse` → `removeFromSuperview`). About 17 ms per row; 509 rows for Finished → All Books. The cost depends on how many of the new rows sort above the old top row, which is why Downloaded → All Books (whose top row is the newest purchase) was fast and why PR #41's merged-library Finished list (93 Audible-marked books, newest first) hid the problem.
- The old harness recorded "busy" from run-loop wake to sleep with one `since` variable; the nested run loop inside the table update reset it, so several 9 s freezes were recorded as 0 ms and the 1 s window cut off the rest.

Fix: `BookTable`, an `NSTableView` behind `NSViewRepresentable` with `usesAutomaticRowHeights = false`, cells updated in place (`noteNumberOfRowsChanged` plus reconfiguring the available row views; `reloadData()` freed and rebuilt all 225 visible cells for 150 ms), cells laid out by hand outside Auto Layout and drawn into one layer per row. Sorting by header click, multiple selection, double-click to play, the context menu (`NSHostingMenu` over `BookActions`), the header menu and View ▸ Table Settings for columns, column autosave, the font size preference and View ▸ Focus Book List are kept. After: every list transition, sort flip and search change settles in 34 to 83 ms of main-thread work; the grid (`LazyVGrid`) was already 44 to 113 ms and is unchanged.

Lessons:
- Measure the transitions the owner actually performs, with the owner's data, in the build configuration the owner runs. One convenient transition on a different data set reported 150 ms for a 9 s freeze.
- A recorder can be the blind spot. Check that the harness sees a deliberately slow case (sleep 1 s on the main thread) before trusting its zeros, and record wall clock from a background thread.
- When a `sample` call tree shows `_doAutomaticRowHeightsForInsertedAndVisibleRows` or hundreds of hosted views created and destroyed per update, the fix is a fixed-height AppKit table, not a tweak to the SwiftUI one.
- An ad-hoc signed test build reading the owner's external disk (`/Volumes/Mac`) blocks in `open()` on the removable-volume consent prompt; a stray build from PR #41 sat there for an hour. Use a local copy of `books.json` and `art/`.

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

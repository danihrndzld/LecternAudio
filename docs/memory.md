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

### A click in the cover grid selected 350 ms late (0.3.4 and 0.3.5)

The owner reported that clicking any cover in the grid took about a second to show the book in the inspector; the list was immediate. Each cell had `.onTapGesture(count: 2)` (play) beside a single tap (select). SwiftUI holds the single tap until the double-click interval has run out, also when the single tap is a `simultaneousGesture` (PR #74 tried that and changed nothing).

Measured with real mouse events posted to the grid (`LECTERN_PERF_FROM=click,dblclick`, Release, 514 books from the owner's catalog, `NSEvent.doubleClickInterval` 0.5 s): selection 384 to 386 ms after mouse down, main thread quiet after 416 to 418 ms, but only about 40 ms of main-thread work. A Time Profiler trace showed the main thread asleep in `mach_msg2_trap` for the rest: a timer, not work. Without the count-2 gesture the selection changed 31 to 35 ms after mouse down (the synthetic mouse up is at 30 ms). The context menu made no difference, and drawing the selection and inspector cost 29 to 40 ms.

Fix: one `onTapGesture` that selects, and plays when `NSApp.currentEvent` is a mouse event with `clickCount == 2`. Check the event type first: `clickCount` raises on any other event, and AppKit swallows exceptions during event dispatch, so the click would silently do nothing. After: selection 31 to 35 ms after mouse down, settled 65 to 72 ms; a double click plays 162 to 177 ms after the first mouse down (the second mouse up is at 160 ms).

Lessons:
- In the harness, post synthetic clicks with `NSApp.postEvent`, not `window.sendEvent`: only a dequeued event sets `NSApp.currentEvent`.
- On macOS 26 the sidebar floats over the detail column, so the grid's scroll view starts at window x 0. Compute click points from the grid's document view plus its safe area; points from the scroll view landed on a sidebar row.
- A sandboxed test build signed differently from an earlier one with the same bundle id hung in `_libsecinit_appsandbox` at launch. For measurements, sign the build ad hoc without the sandbox entitlement.

## Crashes

### Environment objects in table cells (first build)

The app crashed at launch with "No Observable object of type LibraryModel found". AppKit hosts `Table` cells and context menus outside the window's view tree, so they don't inherit `.environment` objects. Pass models into those views as parameters.

### Playing a book crashed the window (PR #23)

When the player bar appeared, it raised the detail column's minimum width. `NSSplitView` applied the new minimum during the constraint pass, and AppKit threw "needs update constraints". The first fix attempt, which moved the bar from a safe area inset into a `VStack`, did not help. A bisection showed that the speed `Picker` gave the bar a large fixed width. The fix is `.frame(minWidth: 0, maxWidth: .infinity)` on any view that appears or disappears inside a split view column. `LECTERN_PLAY=1` reproduces it without clicks.

### 0.3.0 crashed at launch in the cover grid (PR #64)

0.3.0 aborted 3 seconds after launch for the owner, with the same "needs update constraints" exception from `SplitViewChildController.hostingView(_:didUpdateMinSize:maxSize:)`. It needed the cover grid, the OpenAudible folder and the synced Audible list together, and it never happened in the list view or with the demo library. At launch the detail column switches from `Onboarding` to `LibraryGrid` once the books load, and the two report different minimum widths. #59 only changed launch timing: removing either of two unrelated lines from it hid the crash, so a bisect pointed at it but it wasn't the cause. The fix is the same as for the player bar, `minWidth: 0` on the detail column's content and on the inspector's content. To reproduce, build with `CODE_SIGN_ENTITLEMENTS= ENABLE_HARDENED_RUNTIME=NO PRODUCT_BUNDLE_IDENTIFIER=<other id>`, set `viewMode` to true in that domain, and launch with `LECTERN_HARNESS=1 LECTERN_LIBRARY=<copy of books.json and art> LECTERN_SYNCED_LIBRARY=<copy of catalog.json>`. Launch it 5 times, because a timing crash can pass once.

### Summary HTML crashed a system helper (PR #9)

`NSAttributedString` HTML import runs WebKit in `nsattributedstringagent`, which faulted under the sandbox. Use `HTMLText.markdown` for Audible summaries.

### Debug builds crashed at launch after Sparkle was added

An unsandboxed Debug build made with `CODE_SIGN_ENTITLEMENTS=` also dropped `disable-library-validation`, so the hardened runtime refused the ad-hoc signed Sparkle.framework. The owner saw crash dialogs from an agent's build. Build unsandboxed apps with `ENABLE_HARDENED_RUNTIME=NO`, launch them with `open -g`, and check `~/Library/Logs/DiagnosticReports` after each launch.

## Build, signing and release

- Local builds are ad-hoc signed, and releases from 0.3.3 on are signed with the owner's Apple Development certificate (PR #69), not a Developer ID, so neither is notarized. Builds need `com.apple.security.cs.disable-library-validation` to load Sparkle.framework, and Sparkle trusts updates through the EdDSA signature only. A Sparkle installed update has no quarantine attribute and launches without a Gatekeeper prompt, but the first manual install needs Open Anyway or `xattr -dr com.apple.quarantine`.
- Bundled helpers (`ffmpeg`, `aria2c`) carry `app-sandbox` and `inherit` entitlements and must be signed inside out before the app. Run alone, they exit at sandbox init with SIGTRAP, which is expected.
- Renaming the bundle ID gives the app a new sandbox container, so the folder choice, settings and the Audible sign-in must be set up again. Files the app wrote into the user's OpenAudible folder keep their old names (`books/Earmark/`, `earmark-conversions.json`) so they are still found.
- After the rename, a stale generated `Earmark.xcodeproj` made `xcodebuild` refuse to run. Delete old generated projects.

## Workflows and agents

- `gh pr diff` fails with HTTP 406 when a diff is over 20,000 lines, which happens when C libraries are vendored. Automerge now lists PR files through the paginated REST API (PR #36). `gh pr view --json files` is not a replacement, because it returns only the first 100 files.
- Automerge pins the merge to the commit CI tested with `--match-head-commit`, and it skips PRs that touch `.github/` so an agent cannot weaken its own checks (PR #30).
- `xcrun xctrace record --launch` resolved the app by name and started the installed copy in `/Applications` instead of the agent's build, and those stray copies kept running. Record with `--all-processes`, and quit every process you start.
- Agents must work in their own worktree. The owner's checkout once held important uncommitted work, and another session edited it live.
- CI caches (the FFmpeg and aria2 builds, package checkouts and builds, DerivedData) are saved only by the main CI run that automerge dispatches after each merge (PR #83), because a merge with `GITHUB_TOKEN` fires no push event; PR runs only restore them.
- Running `swift test` rewrites `Package.resolved` with a Sparkle pin. Don't commit that change by accident.
- In CI run 38844219657 the `swift test` process froze for about 30 s and ten unrelated tests all reported 30.3 s. The 3-core runner gives Swift concurrency 3 pool threads, and the AVAssetReader export loops and the ffmpeg/aria2c pipe readers (`Task.detached` does not leave the pool) blocked all of them, so the cancel test could not terminate its `sleep 30` child. Blocking work now runs on `BlockingExecutor` (GCD). A 12-core Mac never showed it; `blockingExecutorLeavesCooperativePoolFree` does on any core count.
- The CI runner uses Xcode 26, which failed to compile a large `ContentView` body that Xcode 27 compiled (PR #26). The log was cut off, so the cause is probably type checking time. Splitting the body into helper functions fixed it, so keep view bodies small.

## Download queue

### A wrapped error hid the offline case (issue #31)

The queue failed every restored job on an offline launch, and the fix looked like "treat `URLError`
connection codes as retry later". That check would never have fired: `AudibleHTTP.data(for:)` catches
every transport error and rethrows a private app enum, so the licensing path -- the one that runs
first for each job, through `currentAccount()` -- never surfaces a `URLError` at all. The connection
error is now `ConnectionFailure` in AudibleCore, which both the app and `DownloadQueue.isOffline`
know, and the raw `URLError` codes are still recognised for the download transport, which does throw
them directly.

Lessons:
- Before matching on an error type, follow the throw site. An app-level wrapper two calls away can
  make a plausible-looking check dead code that still compiles and still passes a happy-path test.
- `DownloadModel` lives in the app target, which has no test target, so its state rules now live in
  `DownloadQueue` in AudibleCore and are tested there. Put the decision in core and leave the app
  with the plumbing.
- The late-outcome bug (a Retry reverted to `.cancelled`) was invisible to the `generation` guard,
  because `generation` only changes in `configure`. Guard on the job's current state instead: a task
  that is unwinding has no claim on a job somebody else has already moved on.

## Scope decisions by the owner

- The sign-in window stays a plain Amazon web page. Native email, password and code fields above it, added for Passwords AutoFill, were rejected.
- Web Server, Transcribe, the command line tool, Linux and Windows are `future` issues (#19, #20, #38, #39, #40).

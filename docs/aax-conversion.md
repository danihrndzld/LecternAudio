# AAX → M4B conversion

## Observed OpenAudible behavior

Inspected the installed OpenAudible 5.0.1 package on 2026-10-11. REA identified the Java launcher and the ZIP/JAR payload:

- Artifact: `/Applications/OpenAudible.app/Contents/Resources/app/openaudible_mac_universal.jar`
- SHA-256: `6f3b3189e6acd2125dc57d710a591896a0a032ef733dbe02c31d1f101e09f753`
- REA inventory reference: `ev_fe79258769b302ecc67ef28f1d9d3c811b4e7d03710033b4d179f28af6474bbf`. The full inventory exceeded the MCP transport limit. Its contents were not used to infer conversion behavior.
- Focused static evidence: `javap -p -c` for `org.openaudible.convert.ConvertJob` and `org.openaudible.convert.LookupKey` from that JAR. This inspected bytecode; it did not execute OpenAudible or contact its key service.

`ConvertJob.getM4AArgs` uses `-c:a copy` for AAX/AAXC, maps audio/artwork, adds `-movflags +faststart` and `media_type=2`. Its shared argument builder puts `-activation_bytes` before the AAX input and uses a metadata input for chapters. It selects metadata chapters when the book has a chapter list, otherwise the source chapters. Artwork is an attached picture. This confirms lossless remuxing rather than AAC re-encoding.

`LookupKey.lookupKey` first checks its checksum-indexed cache, then calls `remoteLookup`; the path also checks OpenAudible license membership. Earmark does not reproduce this service or its licensing behavior. The existing `openaudible-spec.md` contains the wider investigation, including earlier observations of staging output and key lookup.

The implementation is independently written against the public [FFmpeg AAX demuxer documentation](https://ffmpeg.org/ffmpeg-formats.html#Audible-AAX) and [FFmpeg command documentation](https://ffmpeg.org/ffmpeg.html). No OpenAudible or GPL conversion code is copied.

## Earmark behavior

### Gap: account-driven automation

The current key field and per-book Keychain entry are an Earmark implementation shortcut, not OpenAudible's user flow. This implementation supplies the conversion engine only; it does not yet reproduce signing in, discovering the account's library, downloading and converting automatically.

A follow-up inspection on 2026-10-11 established:

- `LookupKey.remoteLookup(hash, license)` builds `{serverBase}/api/hash/{hash}/{license}?version=5.0.1`. `lookupKey` tries the local cache first, then this service. Amazon sign-in and OpenAudible's AAX key service are distinct parts of its automatic workflow.
- `API.getLicenseForBook(asin, quality)` obtains the AAXC content response, extracts its URL and codec, and calls `_decrypt_voucher_from_aaxc_response`. `DownloadAAXJob.postProcessAAXC` writes the obtained key/IV voucher to the downloaded file. These are per-content credentials managed internally, not fields the user fills in.
- The installed `GetActivationBytes.extract_activation_bytes` ends by throwing `Exception("Unimplemented")`. Its presence is not evidence that OpenAudible uses a working direct-Audible activation implementation.
- An independent account-based implementation is available as protocol reference in the MIT-licensed [Audible library](https://github.com/mkb79/Audible): `activation_bytes.py` retrieves activation data using registered-device signing, while `aescipher.py` decodes AAXC vouchers. These reference paths were inspected, not tested against the user's live account.

For this follow-up, REA's `open_jeb_project` returned `capability_unavailable` because no JEB MCP engine was running. The method observations above come from focused `javap -p -c` / `-v` inspection of the same installed JAR, not successful REA Java decompilation. No account tokens, license codes or content keys were read or sent to a server.

The intended product flow is account sign-in → library sync → authorized download → automatic key resolution → conversion. Account/session management, account-to-book association, secure key acquisition and the download/conversion queue must be implemented before claiming that workflow is complete. The current raw key prompt should not be presented as its finished UX.

### Pending end-to-end workflow

- [ ] Sign in to Amazon/Audible and register the device; keep session tokens and device credentials in Keychain, with renewal and sign-out handling.
- [ ] Sync the authenticated account's library, associating each book with its owning account and marketplace.
- [ ] Download authorized content with retry, cancellation and resumable queue state; retain the original source until conversion succeeds.
- [ ] Resolve legacy AAX activation data automatically through an independently implemented account-authorized path. Validate the MIT reference against the live protocol before relying on it; do not depend on OpenAudible's licensed service.
- [ ] For AAXC, request the content license and decode its per-content voucher internally; add a separately tested conversion path for its key/IV.
- [ ] Chain download → credential resolution → conversion → library registration, with recoverable errors and no raw-key prompt in the normal account flow. Keep manual local-file import as an advanced fallback.
- [ ] Verify account switching, expired sessions, unavailable licenses, incorrect credentials, interrupted downloads, cancellation and safe retry using offline fixtures, then an explicitly authorized live-account smoke test.

These items are pending, not capabilities included in this commit. AAX activation data belongs to the account; the current per-book Keychain storage is temporary. AAXC vouchers remain content-specific.

### Implemented local-file workflow

1. Select a book with an AAX file and choose **Convert to M4B…** in the inspector, context menu or Conversion menu.
2. Earmark uses its bundled FFmpeg helper. `scripts/build-ffmpeg.sh` downloads the checksum-pinned, unmodified FFmpeg 8.0 archive from ffmpeg.org and compiles only the needed formats/codecs, with GPL/nonfree components disabled. It builds the Xcode target architectures and caches them under `build/ffmpeg-8.0`. The app bundles the source archive, LGPL license and build script under `Contents/Resources/FFmpeg`.
3. Enter the eight hexadecimal activation characters for the account that owns the file. Optional persistence uses Keychain, keyed by book ID. Earmark does not obtain keys automatically. The key is passed to FFmpeg in process arguments as required by its CLI, so it is visible to sufficiently privileged process inspection while conversion runs. It is never written to conversion metadata or application logs. FFmpeg stderr is discarded to prevent accidental key disclosure; failures therefore show a generic actionable message.
4. The core actor runs one conversion at a time. It passes arguments directly to `Process`, without a shell. Audio is copied; a local library cover is preferred, with optional embedded video artwork as fallback. Imported title, author, narrator, genre and summary override corresponding source tags; `ausr` is removed and audiobook media type is set. Valid library chapters override embedded chapters. Missing, overlapping or invalid chapter lists fall back to the source.
5. Progress comes from FFmpeg's machine-readable `out_time_us`, relative to the imported duration. Cancellation terminates the process, escalates after a short grace period, and removes staging files. Missing/incorrect duration affects progress display, not conversion.
6. Output is staged in a unique directory beside the destination. On successful FFmpeg exit, Earmark checks nonempty output and decodes the first second without any key. This is an initial playability check, not a complete decode verification of an entire audiobook. It then moves the result to `books/Earmark/<source name>.m4b`, refusing to replace existing files. The original AAX is kept.
7. `earmark-conversions.json` maps book IDs to converted file paths. Loading the library merges existing outputs into the book list, enabling playback and MP3 export. OpenAudible's `books.json` is never rewritten. If recording fails, the newly converted output is removed so a retry can proceed.

Only local `.aax` input is supported. AAXC, account registration, activation-key recovery, batch scheduling and automatic downloads are outside this change. Existing output collisions are reported rather than overwritten; rename or move the existing output before retrying.

## Verification

```sh
swift test --package-path Packages/AudibleCore
EARMARK_TEST_FFMPEG=/opt/homebrew/bin/ffmpeg swift test --package-path Packages/AudibleCore
xcodegen generate
xcodebuild -scheme Earmark -destination platform=macOS -derivedDataPath build build
```

Offline tests cover key validation/redacted descriptions, argument ordering, chapter escaping and fallback, metadata registration/reload, output collisions, conversion/validation failure, cancellation and staging cleanup. The optional real FFmpeg test generates unencrypted AAC in an MP4 container named `.aax` to exercise remuxing and chapter/tag preservation; it requires a full FFmpeg build with `lavfi` and an AAC encoder. A separate optional encrypted test uses `EARMARK_TEST_AAX` and `EARMARK_TEST_AAX_KEY`, converts the supplied file and rejects an incorrect key. This was run successfully against the public AAX sample linked by the [FFmpeg demuxer contributor](https://ffmpeg.org/pipermail/ffmpeg-devel/2015-July/175788.html). No user secrets or audiobook files are committed as fixtures.

The helper lives in `Contents/Helpers/ffmpeg` and is signed with exactly `app-sandbox` and `inherit` entitlements, following [Apple's helper-tool guidance](https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app). Selecting an external Homebrew executable is insufficient in the App Sandbox, as verified with a sandboxed probe. The app keeps its existing sandbox enabled. CI builds with `CODE_SIGNING_ALLOWED=NO` compile/package the helper but cannot validate signed runtime behavior.

Local verification: 17 tests passed with Xcode 27.1's toolchain targeting macOS 26, including public encrypted-AAX success/wrong-key rejection. The encrypted test also passed with the minimal FFmpeg 8.0 build. A signed sandbox probe converted the public sample in an external folder granted through `NSOpenPanel`; its output duration was 2985.900408 seconds. The signed app built successfully, its nested signatures verified, and the conversion sheet was rendered and visually inspected. Linux CI was not run locally.

For UI snapshots, `EARMARK_CONVERSION_PREVIEW=1` opens the conversion sheet for `EARMARK_SELECT` in debug builds, without reading Keychain or starting a conversion. It works with the existing `EARMARK_LIBRARY` and `EARMARK_SNAPSHOT` debug variables.

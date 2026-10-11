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

### Historical gap: account-driven automation

The initial key field and per-book Keychain entry were an Earmark implementation shortcut, not OpenAudible's user flow. The account-driven workflow described below now replaces that prompt for signed-in library books; manual keys remain available for standalone local imports.

A follow-up inspection on 2026-10-11 established:

- `LookupKey.remoteLookup(hash, license)` builds `{serverBase}/api/hash/{hash}/{license}?version=5.0.1`. `lookupKey` tries the local cache first, then this service. Amazon sign-in and OpenAudible's AAX key service are distinct parts of its automatic workflow.
- `API.getLicenseForBook(asin, quality)` obtains the AAXC content response, extracts its URL and codec, and calls `_decrypt_voucher_from_aaxc_response`. `DownloadAAXJob.postProcessAAXC` writes the obtained key/IV voucher to the downloaded file. These are per-content credentials managed internally, not fields the user fills in.
- The installed `GetActivationBytes.extract_activation_bytes` ends by throwing `Exception("Unimplemented")`. Its presence is not evidence that OpenAudible uses a working direct-Audible activation implementation.
- An independent account-based implementation is available as protocol reference in the MIT-licensed [Audible library](https://github.com/mkb79/Audible): `activation_bytes.py` retrieves activation data using registered-device signing, while `aescipher.py` decodes AAXC vouchers. These reference paths were inspected, not tested against the user's live account.

For this follow-up, REA's `open_jeb_project` returned `capability_unavailable` because no JEB MCP engine was running. The method observations above come from focused `javap -p -c` / `-v` inspection of the same installed JAR, not successful REA Java decompilation. No account tokens, license codes or content keys were read or sent to a server.

The product flow is account sign-in → library sync → authorized download → automatic key resolution → conversion.

### Account-driven workflow

- Sign-in persists the registered device, bearer/refresh tokens, customer identity and registration cookies in Keychain. The browser remains nonpersistent; restoring the app session does not require browser cookies. Older saved sessions obtain missing identity and cookies through Amazon's authenticated profile and cookie-exchange endpoints. Failed restoration preserves the previous Keychain item and asks the user to sign in again.
- Catalogs, outputs and queue files are isolated under `Application Support/Earmark/accounts/<hashed account and marketplace>/`. Signing out cancels current work and hides that account's catalog; saved audio is retained. Signed API requests use an ephemeral transport that rejects redirects. CDN requests carry no account authentication or cookies.
- **Download and Convert** requests a signed, granted AAXC license for the selected ASIN, decodes its voucher in memory and runs FFmpeg with `-audible_key` / `-audible_iv`. No raw license or key is written to disk. For locally imported AAX books present in the synced library, the signed activation endpoint supplies account-level activation data cached in Keychain.
- The serial queue persists metadata and state. Interrupted work requeues on relaunch, while failed/cancelled jobs wait for **Retry**. Downloads use disk-backed HTTP ranges and retain completed chunks; servers that ignore ranges restart the transfer without appending duplicate bytes. Partial files are scoped by a fingerprint of their content credentials. A fresh license is requested on retry/relaunch.
- Output is validated before registration. Existing output left by an interruption is checked before adoption, never overwritten. Original downloads are kept. Embedded chapters/artwork are retained, with license chapters and the library cover used when available.
- **Downloads** exposes progress, cancellation, retry and **Download Missing Books**. Automatic downloading after future syncs is opt-in to avoid unexpectedly transferring an entire library. The inspector, context menu and Conversion menu expose per-book/selection actions.

AAX activation data belongs to the account; AAXC vouchers are content-specific. Offline tests cover registration compatibility, cookie/profile restoration, a voucher known-answer vector generated with OpenSSL, signed requests, malformed/denied licenses, range validation, cancellation, restart and queue restoration. Live-account download/conversion has not been exercised in this change; server-side policy or format differences may still require follow-up. A revoked license is reported rather than bypassed. Split-only titles and non-AAC formats are not implemented.

Protocol references: the MIT-licensed [Audible authentication implementation](https://github.com/mkb79/Audible/blob/master/src/audible/auth.py), [activation endpoint](https://github.com/mkb79/Audible/blob/master/src/audible/activation_bytes.py), [voucher decoding](https://github.com/mkb79/Audible/blob/master/src/audible/aescipher.py), [audible-cli license requests](https://github.com/mkb79/audible-cli/blob/master/src/audible_cli/models.py), and [FFmpeg AAXC input options](https://ffmpeg.org/pipermail/ffmpeg-cvslog/2020-November/125026.html). Amazon profile/deregistration calls use `x-amz-access-token`, matching the current reference rather than its legacy bearer-header convention.

Account-workflow verification: 46 core tests passed locally, including the optional public encrypted-AAX conversion and real FFmpeg remux tests. The signed app built successfully; a downloads-sheet snapshot was rendered with synthetic metadata and Keychain loading disabled. These checks do not prove a live AAXC account download, actual token renewal, or interactive Keychain prompts. No user session secret was read by the development tools; only the presence of the Keychain item was checked.

### Implemented local-file workflow

1. Select a book with an AAX file and choose **Convert to M4B…** in the inspector, context menu or Conversion menu.
2. Earmark uses its bundled FFmpeg helper. `scripts/build-ffmpeg.sh` downloads the checksum-pinned, unmodified FFmpeg 8.0 archive from ffmpeg.org and compiles only the needed formats/codecs, with GPL/nonfree components disabled. It builds the Xcode target architectures and caches them under `build/ffmpeg-8.0`. The app bundles the source archive, LGPL license and build script under `Contents/Resources/FFmpeg`.
3. Enter the eight hexadecimal activation characters for the account that owns the file. Optional persistence uses Keychain, keyed by book ID. Earmark does not obtain keys automatically. The key is passed to FFmpeg in process arguments as required by its CLI, so it is visible to sufficiently privileged process inspection while conversion runs. It is never written to conversion metadata or application logs. FFmpeg stderr is discarded to prevent accidental key disclosure; failures therefore show a generic actionable message.
4. The core actor runs one conversion at a time. It passes arguments directly to `Process`, without a shell. Audio is copied; a local library cover is preferred, with optional embedded video artwork as fallback. Imported title, author, narrator, genre and summary override corresponding source tags; `ausr` is removed and audiobook media type is set. Valid library chapters override embedded chapters. Missing, overlapping or invalid chapter lists fall back to the source.
5. Progress comes from FFmpeg's machine-readable `out_time_us`, relative to the imported duration. Cancellation terminates the process, escalates after a short grace period, and removes staging files. Missing/incorrect duration affects progress display, not conversion.
6. Output is staged in a unique directory beside the destination. On successful FFmpeg exit, Earmark checks nonempty output and decodes the first second without any key. This is an initial playability check, not a complete decode verification of an entire audiobook. It then moves the result to `books/Earmark/<source name>.m4b`, refusing to replace existing files. The original AAX is kept.
7. `earmark-conversions.json` maps book IDs to converted file paths. Loading the library merges existing outputs into the book list, enabling playback and MP3 export. OpenAudible's `books.json` is never rewritten. If recording fails, the newly converted output is removed so a retry can proceed.

The manual local-import path accepts `.aax`; AAXC is handled by the account download workflow. Existing local-import output collisions are reported rather than overwritten; rename or move the existing output before retrying.

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

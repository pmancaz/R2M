# R2M

R2M (“read2me”) is a local reading app built with SwiftUI and an AppKit text view. It retains the **macOS 14 minimum** and the existing import, speech, playback, export and paper-chat workflows.

The interface uses system typography, native rounded controls, one teal accent and selective control-area materials. Generic descriptive copy has been removed. A loaded website or PDF can be reopened from the reader; its original location is saved with the draft after a successful import. Older drafts still load; reimporting their source enables the opening action when no original location was previously saved.

## Sources

`Backend/` contains the Python speech, extraction, cleanup, loudness and paper-chat implementation. Model weights, the Python runtime, bundled FFmpeg and voice preview audio are not stored in Git.

- `Sources/R2M.swift`: reader UI and speech/import/export controller, including the original-source opening action.
- `Sources/Draft.swift`: saved article state, including the optional original source location for compatibility with older drafts.
- `Sources/SourceLocation.swift`: normalization and validation of imported PDF paths and website URLs.
- `Sources/Chat.swift`: paper chat UI and controller.
- `Sources/Listening.swift`: listening-text model.
- `Sources/Appearance.swift`: shared system typography, teal accent, native button styling and control-area materials. The primary button uses the native glass style on macOS 26, with a standard prominent-button fallback on earlier systems. Reduced Transparency uses an opaque surface and the standard button style. No decorative animation is added.

Light and dark appearances use semantic system surfaces and labels. Sliders retain their ranges, precision, bindings and keyboard interaction; switches retain their existing settings and accessible labels.

## Local development preview

`Scripts/preview.py` builds an arm64 development preview with the installed Swift toolchain. All build paths are resolved from the script, so the build remains usable after moving the repository:

```sh
python3 Scripts/preview.py
open 'work/polish/R2M.app'
```

The preview displays the app name **R2M** and uses an executable named `R2M`. It keeps the existing development defaults domain (`local.narrator.polish-preview`) for preference continuity and isolates draft/chat storage under `work/polish/data`.

The preview requires the existing `/Applications/Kokoro.app` installation. Its resource directory is linked to that installation so the Python runtime, models and voices are reused. This dependency path retains its existing name; the script does not modify the installed app or its saved data.

The generated preview is **not a distributable bundle**. Packaging, installation and publication remain separate work. Scratch builds and QA screenshots under `work/` and `outputs/` are excluded from Git.

## Verification

The preceding visual polish was built with SDK 26.5 while retaining the macOS 14 deployment target. The actual preview was checked at the normal 850 × 660 size and existing minimum size, plus dark appearance and the opaque accessibility fallback. Website/PDF import, reference switches, change review, voice previews, speech generation, playback, 192 kbps MP3 export, chat replies and passage sheets worked. Older macOS runtime behavior was not exercised on this Mac.

Source-opening checks passed for a website URL containing a query and fragment, a PDF opened in Preview, undo restoring the previous URL, and persistence across an app restart. Run the source-location regression checks with:

```sh
xcrun swiftc -swift-version 5 -target arm64-apple-macos14.0 Sources/Draft.swift Sources/SourceLocation.swift Sources/Listening.swift Tests/SourceLocationTests.swift -o work/polish/source-location-tests
work/polish/source-location-tests
```

# R2M

R2M (“read2me”) is a native macOS app for local speech, article import and paper chat. It uses SwiftUI/AppKit and supports Apple Silicon Macs running macOS 14 or later. The interface follows the system appearance, with selective material surfaces and accessible native controls.

## Use the staff build

Unzip `outputs/R2M-staff.zip` and copy `R2M.app` to Applications. The app includes its Python runtime, libraries, FFmpeg and voice previews. It runs independently: no Python, Homebrew, Kokoro installation, account or API key is required on the recipient's Mac.

To update an existing installation, quit R2M and replace the app in Applications with the new copy. Your downloaded models, partially completed downloads, saved reading and chat data remain in Application Support; there is no need to remove them. In version 3.1.1, model downloads use macOS certificate verification, including trusted certificates managed by your IT team, rather than depending on Python's static certificate bundle. Certificate and hostname verification remain enabled.

The staff archive is **ad-hoc signed, not Developer ID signed or Apple notarized**. If macOS blocks the test build, the recipient must use Finder's Open action or the system's Privacy & Security Open Anyway control themselves. R2M does not remove quarantine attributes or change security settings. Developer ID signing and notarization remain release work.

Open the Models window in R2M to install only the model sets you need:

| Model set | Download | Purpose |
| --- | ---: | --- |
| Speech | 329,838,060 bytes (about 330 MB) | Kokoro narration with the bundled voices |
| PDF cleanup | 878,857,388 bytes (about 879 MB), optional | Classify publisher boilerplate in imported papers |
| Paper chat | 5,977,073,021 bytes (about 5.98 GB), optional | Qwen3.5-9B MLX 4-bit questions and answers |

The app downloads pinned public files from Hugging Face without an API token and verifies them against `Resources/models.json`. Model cards and license references accompany each set. Models live in `~/Library/Application Support/R2M/Models`; saved reading/chat data live alongside them under `~/Library/Application Support/R2M`. Narration and model inference run locally after installation. Importing a website and downloading models require network access.

Import a PDF or website, choose a voice and speed, then generate speech. Preview buttons let you compare voices. MP3 export is fixed at 192 kbps and can use a remembered folder. Open PDF / Open website reopens the source location saved after a successful import. Older drafts still load; reimporting enables source opening if no original location was previously saved. Paper chat can show the passages cited in its replies.

## Build

Build on an Apple Silicon Mac with the macOS SDK and Swift command-line tools installed:

```sh
python3 Scripts/build.py --zip
```

The build produces `outputs/R2M.app`, `outputs/R2M-staff.zip` and its SHA256 file. The staff ZIP also contains a source snapshot and instructions. The app does not include the large downloadable model sets or any user's documents, recordings or chat history.

For this checkout, the build reads already prepared runtime inputs from `/Applications/Kokoro.app/Contents/Resources`. This is a **build-time source only**, not a dependency of the finished app. To use another prepared runtime directory:

```sh
python3 Scripts/build.py --runtime-source /path/to/runtime-inputs --zip
```

That directory must contain `runtime/` (relocatable Python 3.11 and speech/PDF packages), `chat-packages/` (MLX-LM and tokenizer dependencies), `bin/`, `previews/` and `Kokoro.icns` (or `R2M.icns`). An existing R2M app's `Contents/Resources` directory can itself supply these inputs, so recipients can rebuild from the included source and app without installing Kokoro. The build copies these assets into the app, retains package metadata and license notices, overlays the official macOS 14 MLX wheels pinned in `Resources/chat-runtime.json`, and compiles the Swift sources with the macOS 14 arm64 deployment target. It also installs the small pure-Python `truststore` wheel pinned in `Resources/network-runtime.json` into the main runtime, and checks that the isolated download worker can import it and create a verifying TLS context. All wheel downloads are verified against pinned SHA256 digests. Large runtime assets and weights are excluded from Git.

The builder omits unused Tkinter/IDLE (their Tcl/Tk runtime is not included), removes unused eSpeak CI build-machine RPATHs from bundle copies, checks for external symlinks and native-library paths, and ad-hoc signs the copied native binaries and the app. The installed build inputs are never modified.

After source or backend changes, reuse the already bundled runtime with `python3 Scripts/build.py --refresh --zip`.

For an isolated development preview after building the standalone app:

```sh
python3 Scripts/preview.py
open 'work/polish/R2M.app'
```

The preview keeps the existing development defaults domain (`local.narrator.polish-preview`), isolates draft/chat state under `work/polish/data`, and reuses the standalone build's runtime via relative development-only links. It copies current backend workers and resources from this checkout.

## Source layout

- `Sources/`: native reader, models setup, source opening, paper chat and app appearance.
- `Backend/`: model installer, speech/extraction, PDF cleanup, loudness normalization and local chat workers.
- `Resources/models.json`: pinned model downloads, sizes, digests and license references.
- `Resources/chat-runtime.json`: verified macOS 14 MLX runtime wheel inputs.
- `Resources/network-runtime.json`: verified native certificate-verification runtime wheel input.
- `Resources/THIRD_PARTY_NOTICES.md` and `Resources/Licenses/`: runtime notices and source references.
- `Scripts/`: standalone app and development-preview builders.
- `Tests/`: focused source-location regression checks.

`R2M_DATA_DIR` and `R2M_MODEL_DIR` override app storage locations for isolated local testing. Backend-only model-manifest overrides are intended for downloader tests.

## Notices and source

The app bundles open-source packages with their original notices, including GPLv3 FFmpeg/eSpeak NG and AGPLv3 PyMuPDF/MuPDF. See `Resources/THIRD_PARTY_NOTICES.md`, retained runtime package licenses, and the generated `runtime-packages.json` inventory. Source locations and build references are recorded there; retain them and `R2M-source.zip` when sharing the test build. Free/internal use does not change those component license terms.

## Verification

The standalone staff app was tested from a relocated recipient copy with no dependency on the original installation. First-run model setup, speech-model download cancellation/resume, narration/playback, 192 kbps MP3 export, PDF import and cleanup passed. The paper-chat reasoning cutoff now uses a separate final-answer generation if its private reasoning budget is exhausted; real 9B-model QA and six regression checks passed without exposing planning notes.

The UI was checked at normal 850 × 660 and compact sizes, in light/dark appearances and with the opaque accessibility fallback. Existing import, reference switches, change review, voice preview, narration, playback, 192 kbps MP3 export, chat replies and passage sheets were exercised. Source-opening checks covered exact URLs with query/fragment, local PDFs, undo and persistence across restart.

The packaged MLX 0.32.4 macOS 14 wheels were verified by SHA256 and inspected for macOS 14 native deployment targets. A GPU matrix multiplication and MLX-LM/Qwen3.5 model imports passed using the isolated replacement runtime. The app was built with SDK 26.5 and a macOS 14 deployment target; an older macOS machine has not been used for runtime QA.

Run the source-location regression checks with:

```sh
mkdir -p work/tests
xcrun swiftc -swift-version 5 -target arm64-apple-macos14.0 Sources/Draft.swift Sources/SourceLocation.swift Sources/Listening.swift Tests/SourceLocationTests.swift -o work/tests/source-location-tests
work/tests/source-location-tests
```

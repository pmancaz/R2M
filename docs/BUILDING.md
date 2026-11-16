# Building Read To Me

Build on Apple Silicon with macOS 14+, Python 3 for the scripts, Apple's SDK/Swift Command Line Tools, and uv. The bootstrap script uses uv's managed, relocatable CPython 3.11 distribution from python-build-standalone. It installs the versions in `Resources/requirements-runtime.txt` and `Resources/requirements-chat.txt` into separate directories because speech/cleanup and chat use different Transformers versions.

```sh
python3 Scripts/setup_runtime.py
python3 Scripts/build.py --runtime-source work/runtime-inputs
```

The setup step downloads runtime packages, FFmpeg and spaCy's small English language resource. It does not download Kokoro, DeBERTa or Qwen weights. Those are installed in the app's Models window. Small synthetic voice previews and the icon are included in the source tree.

The builder overlays the macOS 14 MLX wheels pinned in `Resources/chat-runtime.json` and the native TLS package in `Resources/network-runtime.json`, checking SHA256 digests. It copies current backends/resources, inventories packages, removes unused Tkinter/IDLE and unused eSpeak build paths, checks for external symlinks/native dependencies, then ad-hoc signs and verifies the result. It doesn't modify the source runtime.

A prepared runtime can be reused with `--runtime-source /path/to/resources`. It must contain `runtime/`, `chat-packages/`, `bin/`, `previews/` and `R2M.icns` (or the legacy `Kokoro.icns`). The historical default points to a local Kokoro installation; use the explicit public bootstrap path above on a fresh machine.

After the first standalone build:

```sh
python3 Scripts/build.py --refresh
```

`--zip` also creates the legacy `outputs/R2M-staff.zip`, containing the app, source snapshot and instructions. Binary redistribution needs the third-party licences and corresponding-source obligations addressed for the exact binaries supplied. No binary installer is published as part of this source release.

## Verification

```sh
outputs/R2M.app/Contents/Resources/runtime/bin/python3.11 -I -B -m unittest discover -s Tests -p 'test_*.py' -v
python3 Tests/run_native_tests.py
```

The current local macOS 27.2 SDK lacks its SwiftUI macro plugin. On this Mac, selecting the installed 26.5 SDK resolves the compiler error:

```sh
export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
python3 Scripts/build.py --runtime-source work/runtime-inputs
python3 Tests/run_native_tests.py
```

Only set that path if the SDK exists on your Mac. A complete, compatible Xcode toolchain is another option.

For a development preview after a standalone build:

```sh
python3 Scripts/preview.py
open work/polish/R2M.app
```

This uses isolated draft/chat data under `work/polish/data` and development-only links to the standalone runtime. `R2M_DATA_DIR` and `R2M_MODEL_DIR` can override storage for isolated tests. Don't commit those directories or model weights.

## Source layout

- `Sources/`: SwiftUI/AppKit reader, model setup, persistence, export and paper chat.
- `Backend/`: Python extraction, cleanup, speech, audio, downloads and chat workers.
- `Resources/`: model manifests, runtime pins, previews and licences.
- `Scripts/`: runtime preparation, app build and preview build.
- `Tests/`: Python regressions and native controller/filesystem checks.

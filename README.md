# Read To Me (R2M)

A local macOS app for turning papers and articles into narration to listen to while out and about.

I built Read To Me because I wanted to take some of my reading with me. There are papers and articles I want to spend time with, but I don't always want to spend that time in front of a screen. Being able to export a narration and listen to it elsewhere seemed like a fairly useful thing to have.

I also wanted to do this with models running on my own computer. Building the app became a practical way of learning more about AI-assisted programming: installing local models, understanding what each one does, and putting open-source components together into a workflow I could actually use.

This is a personal project, and I'm sharing it because I find it useful. It isn't a commercial venture. I'm still developing my skills and the app along with them, so there will be rough edges.

[Project page](https://pcarroll.au/tools/read-to-me/) · [Installation](#installation) · [Models and acknowledgements](#models-and-acknowledgements) · [Report a problem](https://github.com/pmancaz/R2M/issues)

## What it does

- Imports searchable PDFs, website articles or pasted text.
- Prepares a listening copy of a paper, with controls for boilerplate, citations and references. You can review the changes and restore text.
- Generates narration with five English Kokoro voices and an adjustable reading speed.
- Plays the narration locally and exports a 192 kbps MP3.
- Optionally lets you ask a local language model questions about a paper, with links back to the passages used in its answer.

The app uses SwiftUI/AppKit for its interface and Python workers for extraction, model inference and audio processing. It supports **Apple Silicon Macs with macOS 14 or later**. Windows, Linux and Intel Macs are not supported by this build. Testing has been on a newer Apple Silicon Mac; macOS 14 is the deployment target, rather than a claim of testing on every supported system.

## The pipeline

A PDF contains rather more than the words I want to hear. Page numbers, repeated headers, publisher notices and long reference lists all make sense on a page, but can get in the way when read aloud.

Read To Me extracts the text, then uses formatting rules and an optional DeBERTa classifier to identify material to leave out. It builds a reversible listening plan so I can inspect what changed. This step preserves the author's wording; the classifier scores passages rather than writing new prose. Website extraction uses Trafilatura to separate article text from the surrounding page, while PDF cleanup controls apply to imported papers.

The resulting text goes to Kokoro, which produces the speech locally. FFmpeg normalises the audio's loudness and encodes the exported MP3. The optional Qwen paper-chat model is a separate part of the app; it doesn't rewrite the text used for narration.

While developing this, I tried WAV exports and MP3s at 320 kbps, then 256 kbps, before settling on the current 192 kbps. For this generated speech, I couldn't hear a useful difference that justified the larger files. That was a listening decision for my own use, rather than a controlled comparison or a claim about all audio. The app still uses WAV internally while generating and processing speech.

## Installation

This is a **source release**. The repository contains the app code, small voice previews and build instructions. It does not contain model weights, a prebuilt app or the bundled Python runtime. The setup script downloads runtime dependencies from their upstream sources; models are downloaded separately through the app.

You'll need an Apple Silicon Mac, several GB of free space for the runtime/build, Apple's Command Line Tools and [uv](https://docs.astral.sh/uv/getting-started/installation/). If you use Homebrew, `brew install uv` installs uv. Apple's tools can be installed with `xcode-select --install`.

```sh
git clone https://github.com/pmancaz/R2M.git
cd R2M
python3 Scripts/setup_runtime.py
python3 Scripts/build.py --runtime-source work/runtime-inputs
open outputs/R2M.app
```

When the build finishes, copy `outputs/R2M.app` to Applications if you'd like to keep it there. The finished app includes its runtime, so it doesn't depend on the checkout or a separate Python installation. You can delete the build folders after copying the app.

The local build is ad-hoc signed, **not Developer ID signed or Apple notarised**. If macOS blocks it, use the system's supported Open/Open Anyway controls after reviewing the source. The scripts don't remove quarantine or change security settings.

**SDK note:** the current Command Line Tools macOS 27.2 SDK on my Mac lacks a SwiftUI macro plugin. The build and native tests pass with the installed 26.5 SDK. If you encounter the same `SwiftUIMacros.StateMacro` error and have that SDK installed, use:

```sh
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
  python3 Scripts/build.py --runtime-source work/runtime-inputs
```

See [the build notes](docs/BUILDING.md) for runtime details, rebuilding and verification.

### First launch

1. Open **Models** and download **Speech** (about 330 MB). Downloads come directly from the pinned Hugging Face repositories and are checked against SHA256 digests.
2. Optionally download **Enhanced PDF cleanup** (about 879 MB) and **Paper chat** (about 5.98 GB). Neither is required for basic narration. Paper chat also needs substantially more memory; download size isn't a RAM requirement.
3. Import a searchable PDF or website, or paste some text. Review a paper's listening copy, choose a voice and speed, then generate speech.
4. Listen in the app or use **Export MP3** to save the narration for another device.

No account or API key is needed. Internet access is needed for setup, model downloads and fetching website articles. After installation, narration, PDF cleanup and paper chat run locally. The app does not send imported text to a hosted AI service.

Models live in `~/Library/Application Support/R2M/Models`. Drafts and chat history are stored alongside them under `~/Library/Application Support/R2M`. Replacing the app preserves this data. Your own file-sync or backup software may separately sync folders you save into.

## Models and acknowledgements

These projects made the app possible. I built the interface and the workflow around their work; I didn't train the models.

| Role | Upstream model | Licence |
| --- | --- | --- |
| Narration | [Kokoro-82M, by hexgrad](https://huggingface.co/hexgrad/Kokoro-82M) | Apache-2.0 |
| Optional boilerplate classification | [DeBERTa-v3-large-zeroshot-v2.0, by Moritz Laurer](https://huggingface.co/MoritzLaurer/deberta-v3-large-zeroshot-v2.0) | MIT |
| Optional paper chat | [Qwen3.5-9B](https://huggingface.co/Qwen/Qwen3.5-9B), using [the MLX Community 4-bit conversion](https://huggingface.co/mlx-community/Qwen3.5-9B-MLX-4bit) | Apache-2.0 |

The exact revisions, download URLs, sizes and checksums are recorded in [Resources/models.json](Resources/models.json). The app downloads the relevant model cards as well as the files it needs. Model weights remain with their original hosts and licences.

Thanks also to the people behind [Kokoro and Misaki](https://github.com/hexgrad/kokoro), [PyTorch](https://github.com/pytorch/pytorch), [MLX](https://github.com/ml-explore/mlx), [MLX-LM](https://github.com/ml-explore/mlx-lm), [Trafilatura](https://github.com/adbar/trafilatura), [PyMuPDF/MuPDF](https://github.com/pymupdf/PyMuPDF), [FFmpeg](https://ffmpeg.org/), [eSpeak NG](https://github.com/espeak-ng/espeak-ng), [spaCy](https://spacy.io/), [truststore](https://github.com/sethmlarson/truststore), Python and the other dependencies.

## Limitations and contributions

PDFs with unusual columns or layouts can still extract in the wrong order. Scanned PDFs need OCR before import. Some websites restrict automated access or need JavaScript; in those cases, paste the text instead. Cleanup and paper-chat answers can make mistakes, so check the source when it matters.

If something breaks, [open an issue](https://github.com/pmancaz/R2M/issues) with your macOS version, Mac model and what happened. Please use a short example you can share publicly rather than uploading a private paper or your reading history. Suggestions and pull requests are welcome; see [CONTRIBUTING.md](CONTRIBUTING.md). This is maintained around my own use, so I can't promise a support schedule.

## Licence

The R2M application source is available under the [GNU Affero General Public License v3.0](LICENSE) (AGPL-3.0-only). Dependencies and model weights retain their own licences, including Apache-2.0, MIT, GPLv3 and AGPLv3. See [the third-party notices](Resources/THIRD_PARTY_NOTICES.md) for credits and source references. The setup script downloads dependencies for a local build; this repository doesn't redistribute their large binaries or model weights.

R2M (read2me) — local reading app for Apple Silicon Macs

Version 3.1.1 (build 9)

Requirements
- Apple Silicon Mac (M1 or later), macOS 14 or later.
- Internet access for the first model download. Normal narration, PDF processing
  and paper chat run on your Mac after their models have been installed.
- Allow about 1.5 GB for the app, plus the model sets you choose below.

First use
1. Unzip the staff archive and copy R2M.app to your Applications folder.
2. Open R2M. This is an ad-hoc signed test build, not Developer ID signed or
   notarized by Apple. If macOS blocks it, use Finder's Open action or the
   system's Privacy & Security Open Anyway control yourself. No security
   settings are changed by R2M.
3. Use R2M's Models window to download the speech model. Optional downloads
   enable AI cleanup of imported PDFs and chat about the loaded paper.

Updating an earlier staff build
Quit R2M, then replace R2M.app in Applications with this version. Keep your
Application Support/R2M folder: installed models and saved reading/chat data
are retained, and unfinished model downloads can resume from the Models window.
This version uses macOS certificate verification for model downloads, including
trusted certificates managed by your IT team. It does not disable HTTPS checks
or require you to install Python or certificates separately.

Models (downloaded separately, no account or API key)
- Speech: about 330 MB.
- PDF cleanup: about 879 MB, optional.
- Paper chat: about 5.98 GB, optional.

Model files live in ~/Library/Application Support/R2M/Models. Removing the app
will not remove those files or your saved article/chat data. Downloads can be
cancelled and continued; installed sets are verified against the pinned model
manifest. Keep enough free space for the selected downloads and their installation.

Use
Import a PDF or website, choose a voice and speed, and generate speech. Voice
preview buttons let you compare voices. Export MP3 uses 192 kbps; choosing an
export folder makes subsequent exports one click. The Open PDF / Open website
button reopens the original imported source. Chat can answer questions about
that source and show the passages cited in its replies.

The included R2M-source.zip contains the app's source and build scripts. Detailed
third-party notices are inside R2M.app/Contents/Resources/THIRD_PARTY_NOTICES.md,
with original license files retained beside the runtime packages. Keep the
source snapshot and notices when sharing this build. This is a local staff test
build; no account, subscription or metered API service is required.

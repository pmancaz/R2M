"""Run focused native controller/filesystem regressions in disposable app bundles."""
from pathlib import Path
import json
import os
import plistlib
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def build_and_run(folder, name, sources, setup=None):
    bundle = folder / (name + ".app") / "Contents"
    resources = bundle / "Resources"
    resources.mkdir(parents=True)
    (bundle / "MacOS").mkdir()
    (bundle / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": "local.r2m.tests." + name,
        "CFBundleExecutable": name, "CFBundlePackageType": "APPL"}))
    if setup:
        setup(resources)
    executable = bundle / "MacOS" / name
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
                    "-target", "arm64-apple-macos14.0", *[str(ROOT / path) for path in sources],
                    "-o", str(executable)], check=True, cwd=ROOT)
    env = dict(os.environ, R2M_DATA_DIR=str(folder / (name + "-data")),
               R2M_MODEL_DIR=str(folder / (name + "-models")))
    subprocess.run([str(executable)], env=env, check=True, cwd=ROOT, timeout=30)


def model_fixture(resources):
    (resources / "models.json").write_text(json.dumps({"version": 1, "models": [{
        "id": "speech", "name": "Speech", "revision": "test", "bytes": 1,
        "files": [{"path": "weights.bin", "size": 1, "sha256": "f" * 64}]}]}))
    engine = resources / "runtime/bin/python3.11"
    engine.parent.mkdir(parents=True)
    # Deliberately delay termination so cancellation races are reproducible.
    engine.write_text('''#!/bin/sh
echo "$4" > "$R2M_MODEL_DIR/worker.job"
trap 'sleep 0.4; exit 0' TERM
echo $$ > "$R2M_MODEL_DIR/worker.pid"
while :; do sleep 0.02; done
''')
    engine.chmod(0o755)


def main():
    common = ["Sources/Draft.swift", "Sources/Listening.swift", "Sources/SourceLocation.swift"]
    scratch = ROOT / "work/native-tests"
    scratch.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="run-", dir=scratch) as temporary:
        folder = Path(temporary)
        build_and_run(folder, "SourceLocationTests", common + ["Tests/SourceLocationTests.swift"])
        build_and_run(folder, "ReadingPlanTests", ["Sources/Listening.swift", "Tests/ReadingPlanTests.swift"])
        build_and_run(folder, "AudioExportTests", ["Sources/AudioExport.swift", "Tests/AudioExportTests.swift"])
        build_and_run(folder, "DraftStoreTests", common + ["Sources/DraftStore.swift", "Tests/DraftStoreTests.swift"])
        build_and_run(folder, "ModelSetupTests", ["Sources/AppPaths.swift", "Sources/Appearance.swift",
                      "Sources/ModelSetup.swift", "Tests/ModelSetupTests.swift"], model_fixture)
        build_and_run(folder, "ChatPersistenceTests", common + ["Sources/Chat.swift", "Sources/AppPaths.swift",
                      "Sources/Appearance.swift", "Tests/ChatPersistenceTests.swift"])
        # Compile the actual controller without the app's separate @main scene.
        controller = folder / "Studio.swift"
        controller.write_text((ROOT / "Sources/R2M.swift").read_text().split("struct ReaderView: View {", 1)[0])
        build_and_run(folder, "StudioPersistenceTests", common + ["Sources/AppPaths.swift",
                      "Sources/AudioExport.swift", "Sources/DraftStore.swift", controller,
                      "Tests/StudioPersistenceTests.swift"])


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Prepare public build inputs from upstream packages, without model weights."""
from pathlib import Path
import argparse
import json
import os
import platform
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def run(args, **kwargs):
    return subprocess.run([str(arg) for arg in args], check=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT / 'work/runtime-inputs')
    args = parser.parse_args()
    if sys.platform != 'darwin' or platform.machine() != 'arm64':
        parser.error('Build on an Apple Silicon Mac running macOS 14 or later.')
    uv = shutil.which('uv')
    if not uv:
        parser.error('Install uv first: https://docs.astral.sh/uv/getting-started/installation/')
    output = args.output.expanduser().resolve()
    output.mkdir(parents=True, exist_ok=True)
    # Keep the download cache separate: this copy is the relocatable app runtime.
    downloads = ROOT / 'work/python-downloads'
    run([uv, 'python', 'install', '--no-bin', '--install-dir', downloads, '3.11'])
    env = dict(os.environ, UV_PYTHON_INSTALL_DIR=str(downloads))
    python = Path(run([uv, 'python', 'find', '--managed-python', '3.11'],
                      env=env, capture_output=True, text=True).stdout.strip()).resolve()
    runtime = output / 'runtime'
    if not runtime.exists():
        shutil.copytree(python.parent.parent, runtime, symlinks=True)
    executable = runtime / 'bin/python3.11'
    if not executable.is_file():
        parser.error('The runtime directory exists but has no Python 3.11. Choose a new --output directory.')
    for requirements, target in [
        ('requirements-runtime.txt', runtime / 'lib/python3.11/site-packages'),
        ('requirements-chat.txt', output / 'chat-packages'),
    ]:
        run([uv, 'pip', 'install', '--python', executable, '--target', target,
             '--requirement', ROOT / 'Resources' / requirements])
    binary = Path(run([executable, '-I', '-B', '-c',
                       'import imageio_ffmpeg; print(imageio_ffmpeg.get_ffmpeg_exe())'],
                      capture_output=True, text=True).stdout.strip())
    bin_dir = output / 'bin'
    bin_dir.mkdir(exist_ok=True)
    shutil.copy2(binary, bin_dir / 'ffmpeg')
    for name in ('FFmpeg-GPLv3.txt', 'imageio-ffmpeg-LICENSE.txt'):
        shutil.copy2(ROOT / 'Resources/Licenses' / name, bin_dir / name)
    shutil.copy2(ROOT / 'Resources/R2M.icns', output / 'R2M.icns')
    shutil.copytree(ROOT / 'Resources/previews', output / 'previews', dirs_exist_ok=True)
    # The builder inventories all packages and installs its verified MLX/TLS overlays.
    run([executable, '-I', '-B', '-c',
         'import kokoro, misaki, torch, soundfile, pymupdf, trafilatura, requests, truststore; '
         'assert hasattr(pymupdf.Document, "to_text")'])
    (output / 'setup-provenance.json').write_text(json.dumps({
        'python': run([executable, '--version'], capture_output=True, text=True).stdout.strip(),
        'runtime_requirements': 'Resources/requirements-runtime.txt',
        'chat_requirements': 'Resources/requirements-chat.txt',
        'weights_downloaded': False,
    }, indent=2) + '\n')
    print('Runtime ready: ' + str(output))
    print('Next: python3 Scripts/build.py --runtime-source ' + str(output))


if __name__ == '__main__':
    main()

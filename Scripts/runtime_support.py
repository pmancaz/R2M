"""Pinned, SHA-256-verified runtime build inputs from official PyPI wheels."""
from pathlib import Path
import hashlib
import json
import shutil
from urllib.request import urlopen
import zipfile


def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def mlx_overlay(root):
    manifest = root/'Resources/chat-runtime.json'
    entries = json.loads(manifest.read_text())
    cache = root/'work/runtime-compat'
    cache.mkdir(parents=True, exist_ok=True)
    for item in entries:
        file = cache/item['filename']
        if not file.is_file() or sha256(file) != item['sha256']:
            temporary = file.with_suffix('.download')
            print('Downloading verified macOS 14 runtime: ' + item['filename'], flush=True)
            with urlopen(item['url'], timeout=60) as response, temporary.open('wb') as output:
                shutil.copyfileobj(response, output)
            if sha256(temporary) != item['sha256']:
                temporary.unlink()
                raise RuntimeError('Runtime wheel SHA256 verification failed: ' + item['filename'])
            temporary.replace(file)
    overlay = cache/'mac14'
    if overlay.exists():
        shutil.rmtree(overlay)
    overlay.mkdir()
    for item in entries:
        with zipfile.ZipFile(cache/item['filename']) as archive:
            for name in archive.namelist():
                if not (overlay/name).resolve().is_relative_to(overlay.resolve()):
                    raise RuntimeError('Unexpected runtime archive member: ' + name)
            archive.extractall(overlay)
    shutil.copy2(manifest, overlay/'manifest.json')
    return overlay


def install_network_runtime(root, resources):
    """Always supply native certificate verification, including with older inputs."""
    entries = json.loads((root/'Resources/network-runtime.json').read_text())
    cache = root/'work/network-runtime'
    cache.mkdir(parents=True, exist_ok=True)
    packages = resources/'runtime/lib/python3.11/site-packages'
    for item in entries:
        file = cache/item['filename']
        if not file.is_file() or sha256(file) != item['sha256']:
            temporary = file.with_suffix('.download')
            print('Downloading verified network runtime: ' + item['filename'], flush=True)
            with urlopen(item['url'], timeout=60) as response, temporary.open('wb') as output:
                shutil.copyfileobj(response, output)
            if sha256(temporary) != item['sha256']:
                temporary.unlink()
                raise RuntimeError('Runtime wheel SHA256 verification failed: ' + item['filename'])
            temporary.replace(file)
        with zipfile.ZipFile(file) as archive:
            for name in archive.namelist():
                if not (packages/name).resolve().is_relative_to(packages.resolve()):
                    raise RuntimeError('Unexpected runtime archive member: ' + name)
            # Remove stale package files rather than merging two installed versions.
            for old in (packages/item['name'], *packages.glob(item['name'] + '-*.dist-info')):
                if old.is_dir():
                    shutil.rmtree(old)
                elif old.exists():
                    old.unlink()
            archive.extractall(packages)

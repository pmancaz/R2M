#!/usr/bin/env python3
"""Build a standalone arm64 R2M app, excluding downloadable model weights.

Build inputs are the existing Python/runtime assets, never a runtime dependency
of the finished app. Native sources and backend workers come from this checkout.
"""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
from email.parser import BytesParser
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import zipfile
from runtime_support import install_network_runtime, mlx_overlay, sha256

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_INPUT = Path('/Applications/Kokoro.app/Contents/Resources')
ASSETS = ('runtime', 'chat-packages', 'bin', 'previews')
MAGIC = {b'\xfe\xed\xfa\xce', b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca'}


def run(args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)


def ignore_scratch(directory, names):
    return [name for name in names if name in {'__pycache__', '.DS_Store'} or name.endswith(('.pyc', '.pyo'))]


def macho_files(directory):
    result = []
    for file in directory.rglob('*'):
        if file.is_file() and not file.is_symlink():
            with file.open('rb') as handle:
                if handle.read(4) in MAGIC:
                    result.append(file)
    return result


def native_loads(file):
    output = run(['otool', '-l', file], capture_output=True, text=True).stdout
    command, libraries = '', []
    for line in output.splitlines():
        value = line.strip()
        if value.startswith('cmd '):
            command = value[4:]
        elif value.startswith('name ') and command in {'LC_LOAD_DYLIB', 'LC_LOAD_WEAK_DYLIB', 'LC_REEXPORT_DYLIB', 'LC_LOAD_UPWARD_DYLIB'}:
            libraries.append(value[5:].split(' (offset', 1)[0])
    return file, libraries


def audit_bundle(bundle):
    outside_links = [str(path.relative_to(bundle)) for path in bundle.rglob('*')
                     if path.is_symlink() and not path.resolve().is_relative_to(bundle.resolve())]
    if outside_links:
        raise RuntimeError('Out-of-bundle symlinks: ' + ', '.join(outside_links))
    files = macho_files(bundle)
    invalid = []
    with ThreadPoolExecutor(max_workers=8) as executor:
        for file, libraries in executor.map(native_loads, files):
            for library in libraries:
                if library.startswith('/') and not library.startswith(('/usr/lib/', '/System/Library/')):
                    invalid.append(f'{file.relative_to(bundle)} -> {library}')
    if invalid:
        raise RuntimeError('External native dependencies:\n' + '\n'.join(invalid))
    return files


def inventory(resources):
    packages = []
    for location in (resources/'runtime/lib/python3.11/site-packages', resources/'chat-packages'):
        for info in sorted(location.glob('*.dist-info')):
            metadata = info/'METADATA'
            if not metadata.exists():
                continue
            value = BytesParser().parsebytes(metadata.read_bytes(), headersonly=True)
            license_text = value.get('License-Expression') or value.get('License', '').split('\n')[0].strip()
            packages.append({'name': value.get('Name'), 'version': value.get('Version'),
                             'license': license_text[:240], 'project_urls': value.get_all('Project-URL', []),
                             'metadata': str(metadata.relative_to(resources))})
    return packages


def source_snapshot(destination):
    with zipfile.ZipFile(destination, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        for name in ('Sources', 'Backend', 'Scripts', 'Resources', 'Tests', 'docs'):
            for path in sorted((ROOT/name).rglob('*')):
                if path.is_file() and '__pycache__' not in path.parts and path.suffix != '.pyc':
                    archive.write(path, 'R2M-source/' + str(path.relative_to(ROOT)))
        for name in ('README.md', 'LICENSE', 'CONTRIBUTING.md', 'CHANGELOG.md', '.gitignore'):
            if (ROOT/name).is_file():
                archive.write(ROOT/name, 'R2M-source/' + name)


def publish(staged, output, previous):
    output.parent.mkdir(parents=True, exist_ok=True)
    if previous.exists():
        shutil.rmtree(previous)
    if output.exists():
        output.rename(previous)
    staged.rename(output)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime-source', type=Path, default=DEFAULT_INPUT,
                        help='Build-time resource directory containing runtime, chat-packages, bin, previews and icon')
    parser.add_argument('--chat-overlay', type=Path, help='Verified macOS14 MLX wheel contents to replace chat native packages')
    parser.add_argument('--chat-minimum', default='14.0', help='Minimum OS supported by packaged chat native libraries')
    parser.add_argument('--refresh', action='store_true', help='Reuse runtime assets from outputs/R2M.app while rebuilding source/backend')
    parser.add_argument('--zip', action='store_true', help='Also create outputs/R2M-staff.zip with app, source and staff instructions')
    args = parser.parse_args()
    inputs = ((ROOT/'outputs/R2M.app/Contents/Resources') if args.refresh else args.runtime_source).expanduser().resolve()
    icon = inputs/('R2M.icns' if (inputs/'R2M.icns').is_file() else 'Kokoro.icns')
    missing = [name for name in ASSETS if not (inputs/name).is_dir()]
    if missing or not icon.is_file():
        parser.error('Missing build-time runtime inputs in ' + str(inputs) + ': ' + ', '.join(missing or ['Kokoro.icns']))
    build = ROOT/'work/build'
    build.mkdir(parents=True, exist_ok=True)
    staged = build/'R2M.app'
    if staged.exists():
        shutil.rmtree(staged)
    contents = staged/'Contents'
    resources = contents/'Resources'
    (contents/'MacOS').mkdir(parents=True)
    resources.mkdir()
    print('Copying bundled runtime assets (model weights excluded)…', flush=True)
    for name in ASSETS:
        shutil.copytree(inputs/name, resources/name, symlinks=True, ignore=ignore_scratch)
    install_network_runtime(ROOT, resources)
    # Check the download worker's isolated Python, not the separate chat path.
    # This must fail the build if the native trust dependency is missing or broken.
    network_versions = {item['name']: item['version'] for item in
                        json.loads((ROOT/'Resources/network-runtime.json').read_text())}
    run([resources/'runtime/bin/python3.11', '-I', '-B', '-c',
         'import importlib.metadata, ssl, truststore; '
         f'assert importlib.metadata.version("truststore") == {network_versions["truststore"]!r}; '
         'context = truststore.SSLContext(ssl.PROTOCOL_TLS_CLIENT); '
         'assert context.check_hostname and context.verify_mode == ssl.CERT_REQUIRED'])
    if not args.chat_overlay:
        args.chat_overlay = mlx_overlay(ROOT)
    if args.chat_overlay:
        overlay = args.chat_overlay.expanduser().resolve()
        if not (overlay/'mlx').is_dir():
            parser.error('--chat-overlay must contain the verified mlx package')
        for item in overlay.iterdir():
            if item.name.startswith(('mlx', 'MLX')):
                target = resources/'chat-packages'/item.name
                if target.is_dir():
                    shutil.rmtree(target)
                elif target.exists():
                    target.unlink()
                if item.is_dir():
                    shutil.copytree(item, target, symlinks=True, ignore=ignore_scratch)
                else:
                    shutil.copy2(item, target)
    # Tkinter is unused and its system Tcl/Tk libraries are absent from this runtime.
    python_lib = resources/'runtime/lib/python3.11'
    for item in (python_lib/'lib-dynload').glob('_tkinter*.so'):
        item.unlink()
    for name in ('tkinter', 'idlelib'):
        if (python_lib/name).is_dir():
            shutil.rmtree(python_lib/name)
    # Remove unused CI build paths, while preserving relative loader paths.
    for library in (python_lib/'site-packages/espeakng_loader').glob('*.dylib'):
        output = run(['otool', '-l', library], capture_output=True, text=True).stdout
        command = ''
        for line in output.splitlines():
            value = line.strip()
            if value.startswith('cmd '):
                command = value[4:]
            elif value.startswith('path ') and command == 'LC_RPATH':
                path = value[5:].split(' (offset', 1)[0]
                if path.startswith('/Users/runner/'):
                    run(['install_name_tool', '-delete_rpath', path, library], capture_output=True)
    shutil.copy2(icon, resources/'R2M.icns')
    for path in (ROOT/'Backend').glob('*.py'):
        shutil.copy2(path, resources/path.name)
    shutil.copytree(ROOT/'Resources', resources, dirs_exist_ok=True, ignore=ignore_scratch)
    if (inputs/'setup-provenance.json').is_file():
        shutil.copy2(inputs/'setup-provenance.json', resources/'setup-provenance.json')
    (resources/'runtime-packages.json').write_text(json.dumps(inventory(resources), indent=2) + '\n')
    if args.chat_overlay and (args.chat_overlay/'manifest.json').is_file():
        shutil.copy2(args.chat_overlay/'manifest.json', resources/'chat-runtime-provenance.json')
    source_snapshot(resources/'R2M-source.zip')
    info = {
        'CFBundleName': 'R2M', 'CFBundleDisplayName': 'R2M', 'CFBundleExecutable': 'R2M',
        'CFBundleIdentifier': 'local.r2m.reader', 'CFBundlePackageType': 'APPL',
        'CFBundleShortVersionString': '3.1.2', 'CFBundleVersion': '10',
        'CFBundleIconFile': 'R2M.icns', 'LSMinimumSystemVersion': '14.0',
        'R2MChatMinimumSystemVersion': args.chat_minimum,
        'NSHighResolutionCapable': True, 'NSPrincipalClass': 'NSApplication',
        'NSHumanReadableCopyright': 'R2M',
        'CFBundleDocumentTypes': [{'CFBundleTypeName': 'PDF document', 'CFBundleTypeRole': 'Viewer',
                                  'LSHandlerRank': 'Alternate', 'LSItemContentTypes': ['com.adobe.pdf']}],
    }
    (contents/'Info.plist').write_bytes(plistlib.dumps(info))
    print('Compiling native app for macOS 14 arm64…', flush=True)
    run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', '-target', 'arm64-apple-macos14.0',
         *sorted((ROOT/'Sources').glob('*.swift')), '-o', contents/'MacOS/R2M'])
    print('Checking native dependencies and signing local build…', flush=True)
    files = audit_bundle(staged)
    for file in files:
        if file != contents/'MacOS/R2M':
            run(['codesign', '--force', '--sign', '-', '--timestamp=none', file], capture_output=True)
    run(['codesign', '--force', '--sign', '-', '--timestamp=none', staged], capture_output=True)
    run(['codesign', '--verify', '--deep', '--strict', staged], capture_output=True)
    output = ROOT/'outputs/R2M.app'
    publish(staged, output, build/'R2M.previous.app')
    if args.zip:
        share = build/'R2M-staff'
        if share.exists():
            shutil.rmtree(share)
        share.mkdir()
        # APFS clones avoid a second large physical copy on the build Mac.
        run(['cp', '-cR', output, share/'R2M.app'])
        shutil.copy2(ROOT/'Resources/STAFF_README.txt', share/'READ ME.txt')
        shutil.copy2(output/'Contents/Resources/R2M-source.zip', share/'R2M-source.zip')
        archive = ROOT/'outputs/R2M-staff.zip'
        if archive.exists():
            archive.unlink()
        print('Creating staff archive…', flush=True)
        run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', share, archive])
        digest = sha256(archive)
        (ROOT/'outputs/R2M-staff.zip.sha256').write_text(digest + '  R2M-staff.zip\n')
        print(archive, flush=True)
    size = sum(file.stat().st_size for file in output.rglob('*') if file.is_file())
    print(f'{output}\nApp size: {size:,} bytes; native files checked: {len(files)}', flush=True)


if __name__ == '__main__':
    main()

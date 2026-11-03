from pathlib import Path
import plistlib, subprocess, json, shutil, os
root=Path(__file__).resolve().parent.parent
work=root/'work/polish'
source=work/'preview-sources'
source.mkdir(parents=True, exist_ok=True)
# Remove only obsolete generated Swift files after source renames.
current_sources = {item.name for item in (root/'Sources').glob('*.swift')}
for stale in source.glob('*.swift'):
    if stale.name not in current_sources:
        stale.unlink()
# Isolate QA drafts/chats and expose appearance checks only in generated test sources.
for item in (root/'Sources').glob('*.swift'):
    text=item.read_text()
    text=text.replace('FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]', 'URL(fileURLWithPath: '+json.dumps(str(work/'data'))+')')
    if item.name == 'Appearance.swift':
        text=text.replace('if reduceTransparency {', 'if reduceTransparency || CommandLine.arguments.contains("--reduce-transparency") {')
        text=text.replace('!reduceTransparency {', '!reduceTransparency, !CommandLine.arguments.contains("--reduce-transparency") {')
    if item.name == 'R2M.swift':
        text=text.replace('.defaultSize(width: 850, height: 660)', '.defaultSize(width: CommandLine.arguments.contains("--compact") ? 660 : 850, height: CommandLine.arguments.contains("--compact") ? 490 : 660)')
        for view in ['ReaderView(studio: studio)', 'PaperChatView(chat: chat, studio: studio)']:
            text=text.replace(view+' }', view+'.preferredColorScheme(CommandLine.arguments.contains("--dark") ? .dark : .light) }')
    (source/item.name).write_text(text)
base = root/'outputs/R2M.app'
if not (base/'Contents/Resources/runtime').is_dir():
    raise SystemExit('Build the standalone runtime first: python3 Scripts/build.py')
bundle=work/'R2M.app'
(bundle/'Contents/MacOS').mkdir(parents=True,exist_ok=True)
resource=bundle/'Contents/Resources'
if resource.is_symlink():
    resource.unlink()
resource.mkdir(parents=True, exist_ok=True)
for name in ('runtime', 'chat-packages', 'bin', 'previews', 'R2M.icns'):
    target = resource/name
    if target.is_symlink(): target.unlink()
    if not target.exists():
        target.symlink_to(os.path.relpath(base/'Contents/Resources'/name, resource))
for item in (root/'Backend').glob('*.py'):
    shutil.copy2(item, resource/item.name)
shutil.copytree(root/'Resources', resource, dirs_exist_ok=True,
                ignore=shutil.ignore_patterns('__pycache__', '*.pyc'))
info=plistlib.loads((base/'Contents/Info.plist').read_bytes())
info.update(CFBundleIdentifier='local.narrator.polish-preview', CFBundleDisplayName='R2M',
            CFBundleName='R2M', CFBundleExecutable='R2M',
            NSHumanReadableCopyright='R2M')
(bundle/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library','-target','arm64-apple-macos14.0',*map(str,sorted(source.glob('*.swift'))),'-o',str(bundle/'Contents/MacOS/R2M')],check=True)
# Local development launch only; no distribution package or installation.
subprocess.run(['codesign','--force','--sign','-','--timestamp=none',str(bundle)],check=True)
print(bundle)

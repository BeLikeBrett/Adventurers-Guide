#!/usr/bin/env python3
"""Build a public release from an explicit source allowlist."""
from pathlib import Path
import json
import re
import zipfile

ROOT = Path(__file__).resolve().parent
RUNTIME = ROOT / 'companion' if (ROOT / 'companion').is_dir() else ROOT
BRIDGE = ['bridge.js', 'agents.js', 'protocol.js', 'install-slots.js',
          'capture_wayland.py', 'capture_x11.py', 'capture_mac.py', 'capture.ps1',
          'copilot-ipc.js', 'copilot-mcp.mjs', 'copilot-state.js', 'copilot-vision.js',
          'character-notes.js', 'forever-sources.js', 'addon-catalog.js', 'reference-cards.js',
          'pixel_codec.py', 'prompt-context.js', 'setup-core.js', 'setup.mjs', 'setup.html', 'setup-ui.js']
ADDON = ['Codec.lua', 'Inbox.lua', 'WoWAI.lua', 'Map.lua', 'Integrations.lua',
         'References.lua', 'Combat.lua', 'Auctions.lua', 'Snapshot.lua', 'WoWAI.toc', 'Art/GuideIcon.tga', 'Art/GuideIcon.png']

def main():
    version = json.loads((RUNTIME / 'package.json').read_text())['version']
    output = ROOT / 'dist' / f'AdventurersGuide-{version}.zip'
    output.parent.mkdir(exist_ok=True)
    relative = str(RUNTIME.relative_to(ROOT))
    prefix = '' if relative == '.' else relative + '/'
    entries = {'README.md': 'README.md', 'LICENSE': 'LICENSE', 'images/journal.png':'images/journal.png', 'images/setup.png':'images/setup.png'}
    entries.update({f'addon/WoWAI/{f}': f for f in ADDON})
    entries.update({prefix+f'bridge/{f}': f'companion/bridge/{f}' for f in BRIDGE})
    entries.update({prefix+f'copilot/{f}': f'companion/copilot/{f}' for f in ['AGENTS.md', 'PRIMER.md']})
    entries.update({prefix+f: f'companion/{f}' for f in ['package.json', 'package-lock.json']})
    entries.update({'launcher/Start Guide.cmd':'Start Guide.cmd','launcher/Start Guide.sh':'Start Guide.sh','launcher/start-windows.ps1':'companion/start-windows.ps1'})
    with zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED) as release:
        for source, target in sorted(entries.items()):
            data = (ROOT / source).read_bytes()
            if source == prefix+'package.json':
                package = json.loads(data)
                package.pop('bin', None)
                package['scripts'] = {k: v for k, v in package['scripts'].items() if k in ['start', 'slots', 'mcp']}
                data = (json.dumps(package, indent=2) + '\n').encode()
            if source.endswith(('.json', '.md', '.py', '.js', '.mjs', '.lua', '.toc')):
                if re.search(rb'/(?:home|Users)/[^/\s]+/',data):
                    raise ValueError('Personal path or account in public source: ' + source)
            info=zipfile.ZipInfo('WoWAI/' + target)
            info.compress_type=zipfile.ZIP_DEFLATED
            info.external_attr=(0o100755 if target.endswith('.sh') else 0o100644)<<16
            release.writestr(info, data)
    with zipfile.ZipFile(output) as release:
        names = release.namelist()
        assert len(names) == len(entries)
        assert not any(Path(n).name in ['config.json', 'state.json', 'transcripts.json', 'character-notes.json', 'copilot.sock'] for n in names)
    print(f'{output} ({output.stat().st_size:,} bytes, {len(entries)} files)')

if __name__ == '__main__':
    main()

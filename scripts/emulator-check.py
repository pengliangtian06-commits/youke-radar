"""Small hdc/uitest helper for repeatable local emulator acceptance checks."""
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HDC = r'C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe'

def run(*args):
    return subprocess.run([HDC, '-t', '127.0.0.1:5555', *args], capture_output=True, text=True, encoding='utf-8', errors='replace', check=True).stdout

def layout():
    run('shell', 'uitest', 'dumpLayout', '-p', '/data/local/tmp/radar-layout.json')
    run('file', 'recv', '/data/local/tmp/radar-layout.json', str(ROOT / 'reports/emulator-layout.json'))
    return json.loads((ROOT / 'reports/emulator-layout.json').read_text(encoding='utf-8'))

def nodes(node):
    yield node.get('attributes', {})
    for child in node.get('children', []):
        yield from nodes(child)

action = sys.argv[1] if len(sys.argv) > 1 else 'dump'
tree = layout()
if action == 'tap':
    matches = [n for n in nodes(tree) if n.get('text') == sys.argv[2]]
    if len(matches) != 1:
        raise SystemExit(f'Expected one matching label, found {len(matches)}')
    bounds = list(map(int, re.findall(r'\d+', matches[0]['bounds'])))
    print(run('shell', 'uitest', 'uiInput', 'click', str((bounds[0] + bounds[2]) // 2), str((bounds[1] + bounds[3]) // 2)))
elif action == 'dump':
    for n in nodes(tree):
        if n.get('text'):
            print(n['text'], n.get('bounds'), n.get('type'))
elif action == 'capture':
    name = sys.argv[2] if len(sys.argv) > 2 else 'emulator'
    run('shell', 'uitest', 'screenCap', '-p', '/data/local/tmp/radar.png')
    run('file', 'recv', '/data/local/tmp/radar.png', str(ROOT / f'reports/{name}.png'))
else:
    raise SystemExit('dump | tap <exact label> | capture <name>')

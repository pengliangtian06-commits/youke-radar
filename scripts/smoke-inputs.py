"""Real model end-to-end smoke test against synthetic text/image/PDF inputs."""
import asyncio
import base64
import json
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from dotenv import load_dotenv
load_dotenv(ROOT / '.env')
from fastapi.testclient import TestClient
from backend.main import create_app

results = []
with tempfile.TemporaryDirectory() as directory:
    client = TestClient(create_app(str(Path(directory) / 'test.sqlite3')))
    for kind, name in [('image', 'notice.png'), ('pdf', 'course-outline.pdf')]:
        begin = time.perf_counter()
        response = client.post('/materials/parse', json={'kind': kind, 'name': name,
            'content_base64': base64.b64encode((ROOT / 'demo' / name).read_bytes()).decode()})
        data = response.json()
        item = {'kind': kind, 'status': response.status_code, 'seconds': round(time.perf_counter() - begin, 2)}
        if response.status_code == 200:
            candidates = data['candidates']
            item['tasks'] = [c['task'] for c in candidates]
            item['passed'] = len(candidates) == 1 and candidates[0]['task']['due_at'] is not None and candidates[0]['task']['course'] == '计算机网络'
            if kind == 'image' and candidates:
                c = candidates[0]
                confirmed = client.post(f"/candidates/{c['id']}/confirm", json={'task': c['task'], 'estimated_minutes': 120})
                item['confirmation_status'] = confirmed.status_code
        else:
            item['passed'] = False
            item['error'] = data
        results.append(item)
    change = client.post('/materials/parse', json={'text': (ROOT / 'demo' / 'change.txt').read_text(encoding='utf-8')})
    if change.status_code == 200 and change.json()['candidates']:
        candidate = change.json()['candidates'][0]
        before = client.get('/tasks').json()[0]
        confirmed = client.post(f"/candidates/{candidate['id']}/confirm", json={'task': candidate['task'], 'estimated_minutes': 120})
        after = confirmed.json()
        results.append({'kind': 'change_confirmation', 'passed': confirmed.status_code == 200 and before['due_at'] != after['due_at']
                        and before['requirements'] == after['requirements'], 'status': confirmed.status_code})
    else:
        results.append({'kind': 'change_confirmation', 'passed': False, 'status': change.status_code, 'error': change.json()})
(ROOT / 'reports' / 'input-smoke.json').write_text(json.dumps(results, ensure_ascii=False, indent=2), encoding='utf-8')
print(json.dumps([{k: v for k, v in r.items() if k != 'tasks'} for r in results], ensure_ascii=False))

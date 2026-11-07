import base64
import json
import os
import time
import uuid
from datetime import datetime
from pathlib import Path

from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import Response

from . import extractor
from .models import ConfirmInput, EditInput, FIELDS, MaterialInput, PlanInput, TZ
from .scheduler import generate_plan
from .store import Store

load_dotenv(Path(__file__).resolve().parents[1] / '.env')


def now():
    return datetime.now(TZ).isoformat()


def create_app(db_path: str | None = None):
    app = FastAPI(title='邮课雷达', version='1.0.0')
    store = Store(db_path or os.getenv('RADAR_DB', 'data/radar.sqlite3'))
    app.state.store = store

    @app.middleware('http')
    async def limit_request(request: Request, call_next):
        if request.method in ('POST', 'PUT', 'PATCH'):
            size = 0
            chunks = []
            async for chunk in request.stream():
                size += len(chunk)
                if size > 15 * 1024 * 1024:
                    return Response('请求超过 15 MB', status_code=413)
                chunks.append(chunk)
            request._body = b''.join(chunks)
        return await call_next(request)

    @app.get('/health')
    def health():
        return {'status': 'ok', 'model_configured': all(os.getenv(x) for x in ('MODEL_BASE_URL', 'MODEL_NAME', 'MODEL_API_KEY')),
                'timezone': 'Asia/Shanghai', 'version': '1.0.0'}

    @app.get('/tasks')
    def tasks():
        return store.all('task')

    @app.get('/candidates')
    def candidates():
        return [c for c in store.all('candidate') if not c.get('confirmed_task_id')]

    @app.get('/materials/{material_id}')
    def material(material_id: str):
        value = store.get('material', material_id)
        if not value:
            raise HTTPException(404, '材料不存在')
        return {k: v for k, v in value.items() if k != 'content_base64'}

    @app.get('/materials/{material_id}/file')
    def material_file(material_id: str):
        value = store.get('material', material_id)
        if not value:
            raise HTTPException(404, '材料不存在')
        if value['kind'] == 'text':
            return Response(value['text'], media_type='text/plain')
        raw = base64.b64decode(value['content_base64'])
        mime = 'application/pdf' if value['kind'] == 'pdf' else ('image/png' if raw.startswith(b'\x89PNG') else 'image/jpeg')
        return Response(raw, media_type=mime)

    @app.post('/materials/parse')
    async def parse(payload: MaterialInput):
        started = time.perf_counter()
        extraction, pages = await extractor.extract(payload)
        material_id = uuid.uuid4().hex
        source = payload.model_dump(mode='json') | {'id': material_id, 'pages': pages, 'created_at': now()}
        store.put('material', material_id, source)
        existing = store.all('task')
        output = []
        for extracted in extraction.tasks:
            data = extracted.model_dump(mode='json')
            for evidence in data['evidence']:
                evidence['material_id'] = material_id
            # Conservative identity: course AND title. Ambiguity requires explicit selection.
            matched = [t for t in existing if t['course'].strip() == data['course'].strip()
                       and t['title'].strip() == data['title'].strip()]
            target = matched[0] if len(matched) == 1 else None
            candidate = {'id': uuid.uuid4().hex, 'material_id': material_id, 'source_name': payload.name,
                         'task': data, 'target_id': target['id'] if target else None,
                         'expected_version': target['version'] if target else None,
                         'requires_target': bool(extracted.is_update or len(matched) > 1),
                         'changes': [{'field': f, 'before': target[f], 'after': data[f]} for f in FIELDS
                                     if target and data[f] and target[f] != data[f]],
                         'created_at': now()}
            store.put('candidate', candidate['id'], candidate)
            output.append(candidate)
        return {'material_id': material_id, 'candidates': output, 'elapsed_ms': round((time.perf_counter() - started) * 1000),
                'message': '未发现可提取的课业任务' if not output else '请核对原文并确认任务'}

    @app.post('/candidates/{candidate_id}/confirm')
    def confirm(candidate_id: str, payload: ConfirmInput):
        with store.connect() as db:
            db.execute('BEGIN IMMEDIATE')
            candidate = store.get('candidate', candidate_id, db)
            if not candidate:
                raise HTTPException(404, '候选任务不存在')
            if candidate.get('confirmed_task_id'):
                return store.get('task', candidate['confirmed_task_id'], db)
            # Omission accepts the suggested match; explicit null means create a new
            # task. Do not silently override that user choice with the suggestion.
            target_id = payload.target_id if 'target_id' in payload.model_fields_set else candidate['target_id']
            if candidate['requires_target'] and not target_id and (
                    candidate['task']['is_update'] or 'target_id' not in payload.model_fields_set):
                raise HTTPException(422, '变更通知需先选择对应的已有任务')
            previous = store.get('task', target_id, db) if target_id else None
            if target_id and not previous:
                raise HTTPException(404, '原任务不存在')
            expected = payload.expected_version
            if expected is None and target_id == candidate['target_id']:
                expected = candidate['expected_version']
            if previous and expected != previous['version']:
                raise HTTPException(409, '任务已被更新，请刷新后重新核对变更')
            task = payload.task.model_dump(mode='json')
            manual_fields = {f for f in FIELDS if task[f] != candidate['task'][f]}
            # Evidence supplied by the client is never promoted to model/source evidence.
            task['evidence'] = candidate['task']['evidence']
            if previous:
                # A partial change notice must not erase old requirements or evidence.
                for field in FIELDS:
                    if not task[field]:
                        task[field] = previous[field]
                        task['evidence'] = [e for e in task['evidence'] if e['field'] != field] + [
                            e for e in previous['evidence'] if e['field'] == field]
                        # An inherited value retains its provenance status. A partial
                        # notice must not make an earlier manual edit look extracted.
                        if field in previous.get('manual_fields', []):
                            manual_fields.add(field)
            task['manual_fields'] = [f for f in FIELDS if f in manual_fields]
            source_ids = list(dict.fromkeys((previous.get('source_ids', []) if previous else []) + [candidate['material_id']]))
            task.update({'id': target_id or uuid.uuid4().hex, 'version': previous['version'] + 1 if previous else 1,
                         'estimated_minutes': payload.estimated_minutes, 'completed': previous.get('completed', False) if previous else False,
                         'source_ids': source_ids, 'material_id': candidate['material_id'], 'source_name': candidate['source_name'],
                         'updated_at': now(), 'confirmed_by_user': True})
            if previous:
                db.execute('INSERT INTO history VALUES (?,?,?)', (task['id'], previous['version'], json.dumps(previous, ensure_ascii=False)))
            store.put('task', task['id'], task, db)
            candidate['confirmed_task_id'] = task['id']
            store.put('candidate', candidate_id, candidate, db)
            return task

    @app.put('/tasks/{task_id}')
    def edit(task_id: str, payload: EditInput):
        with store.connect() as db:
            db.execute('BEGIN IMMEDIATE')
            previous = store.get('task', task_id, db)
            if not previous:
                raise HTTPException(404, '任务不存在')
            if payload.expected_version != previous['version']:
                raise HTTPException(409, '任务已被更新，请刷新后重试')
            task = previous | payload.task.model_dump(mode='json') | {
                'version': previous['version'] + 1, 'estimated_minutes': payload.estimated_minutes,
                'completed': payload.completed, 'updated_at': now()}
            # Manual changes remain visibly distinct from extraction evidence.
            task['manual_fields'] = [f for f in FIELDS if task[f] != previous[f] or f in previous.get('manual_fields', [])]
            task['evidence'] = previous['evidence']
            db.execute('INSERT INTO history VALUES (?,?,?)', (task_id, previous['version'], json.dumps(previous, ensure_ascii=False)))
            store.put('task', task_id, task, db)
            return task

    @app.get('/tasks/{task_id}/history')
    def history(task_id: str):
        return store.history(task_id)

    @app.get('/plan')
    def get_plan():
        return store.get('state', 'plan') or {'slots': [], 'unassigned': [], 'conflicts': 0}

    @app.post('/plan')
    def plan(payload: PlanInput):
        last = store.get('state', 'plan')
        result = generate_plan(store.all('task'), payload, last['slots'] if last else None)
        result['input'] = payload.model_dump(mode='json')
        store.put('state', 'plan', result)
        return result

    @app.get('/evaluation/cases')
    def evaluation_cases():
        from .evaluation import CASES
        return CASES

    @app.post('/evaluation/run')
    async def evaluation():
        from .evaluation import evaluate
        result = await evaluate(extractor.extract)
        store.put('state', 'evaluation', result)
        return result

    @app.get('/evaluation/latest')
    def latest_evaluation():
        return store.get('state', 'evaluation') or {'status': 'not_run', 'message': '尚未运行真实模型评测'}

    return app


app = create_app()

import asyncio
import base64
from datetime import datetime
from unittest.mock import AsyncMock

import httpx
import pytest
from fastapi import HTTPException
from fastapi.testclient import TestClient

from backend import extractor
from backend.main import create_app
from backend.models import ExtractedTask, Extraction, MaterialInput, PlanInput
from backend.scheduler import generate_plan


@pytest.fixture
def client(tmp_path):
    return TestClient(create_app(str(tmp_path / 'test.sqlite3')))


def sample(**kwargs):
    return ExtractedTask(course='计算机网络', title='实验一', due_at='2026-11-10T20:00:00+08:00',
                         submission='教学平台', requirements='PDF报告', **kwargs)


def parse(client, monkeypatch, task=None):
    monkeypatch.setattr(extractor, 'extract', AsyncMock(return_value=(Extraction(tasks=[task or sample()]), ['原文'])))
    response = client.post('/materials/parse', json={'text': '通知内容'})
    assert response.status_code == 200
    return response.json()['candidates'][0]


def confirm(client, candidate, **kwargs):
    return client.post(f"/candidates/{candidate['id']}/confirm", json={
        'task': candidate['task'], 'estimated_minutes': 120, **kwargs})


def test_confirmation_required_and_idempotent(client, monkeypatch):
    candidate = parse(client, monkeypatch)
    assert client.get('/tasks').json() == []
    first = confirm(client, candidate)
    assert first.status_code == 200
    assert confirm(client, candidate).json()['id'] == first.json()['id']
    assert len(client.get('/tasks').json()) == 1


def test_update_preserves_fields_and_records_history(client, monkeypatch):
    original = confirm(client, parse(client, monkeypatch)).json()
    update = ExtractedTask(course='计算机网络', title='实验一', due_at='2026-11-09T20:00:00+08:00', is_update=True)
    candidate = parse(client, monkeypatch, update)
    assert client.get('/tasks').json()[0]['due_at'] == original['due_at']
    saved = confirm(client, candidate).json()
    assert saved['due_at'] != original['due_at']
    assert saved['requirements'] == 'PDF报告'
    assert saved['version'] == 2
    assert client.get(f"/tasks/{saved['id']}/history").json()[0] == original


def test_stale_update_rejected(client, monkeypatch):
    confirm(client, parse(client, monkeypatch))
    pending = parse(client, monkeypatch)
    other = parse(client, monkeypatch)
    assert confirm(client, other).status_code == 200
    assert confirm(client, pending).status_code == 409


def test_unmatched_update_requires_selection(client, monkeypatch):
    candidate = parse(client, monkeypatch, sample(is_update=True))
    assert confirm(client, candidate).status_code == 422


def test_explicit_new_task_choice_does_not_overwrite_suggested_match(client, monkeypatch):
    original = confirm(client, parse(client, monkeypatch)).json()
    candidate = parse(client, monkeypatch)
    assert candidate['target_id'] == original['id']
    saved = confirm(client, candidate, target_id=None).json()
    assert saved['id'] != original['id']
    assert len(client.get('/tasks').json()) == 2
    assert client.get(f"/tasks/{original['id']}/history").json() == []


def test_explicit_null_target_rejects_change_notice(client, monkeypatch):
    confirm(client, parse(client, monkeypatch))
    candidate = parse(client, monkeypatch, sample(is_update=True))
    assert candidate['target_id']
    assert confirm(client, candidate, target_id=None).status_code == 422


def test_manual_edit_can_clear_due_and_complete(client, monkeypatch):
    task = confirm(client, parse(client, monkeypatch)).json()
    value = {k: task[k] for k in ExtractedTask.model_fields}
    value['due_at'] = None
    response = client.put(f"/tasks/{task['id']}", json={'task': value, 'estimated_minutes': 60,
        'expected_version': 1, 'completed': True})
    assert response.status_code == 200
    assert response.json()['due_at'] is None
    assert response.json()['completed']
    assert 'due_at' in response.json()['manual_fields']


def test_completion_toggle_preserves_manual_provenance(client, monkeypatch):
    task = confirm(client, parse(client, monkeypatch)).json()
    value = {k: task[k] for k in ExtractedTask.model_fields}
    value['requirements'] = '人工补充要求'
    edited = client.put(f"/tasks/{task['id']}", json={'task': value, 'estimated_minutes': 120,
        'expected_version': task['version'], 'completed': False}).json()
    completed = client.put(f"/tasks/{task['id']}", json={'task': value, 'estimated_minutes': 120,
        'expected_version': edited['version'], 'completed': True}).json()
    assert 'requirements' in completed['manual_fields']


def test_partial_update_preserves_inherited_manual_provenance(client, monkeypatch):
    task = confirm(client, parse(client, monkeypatch)).json()
    value = {k: task[k] for k in ExtractedTask.model_fields}
    value['requirements'] = '人工补充要求'
    client.put(f"/tasks/{task['id']}", json={'task': value, 'estimated_minutes': 120,
        'expected_version': task['version'], 'completed': False})
    update = ExtractedTask(course='计算机网络', title='实验一', due_at='2026-11-09T20:00:00+08:00', is_update=True)
    saved = confirm(client, parse(client, monkeypatch, update)).json()
    assert saved['requirements'] == '人工补充要求'
    assert 'requirements' in saved['manual_fields']


def test_restart_persists(tmp_path, monkeypatch):
    path = str(tmp_path / 'persistent.sqlite3')
    first = TestClient(create_app(path))
    task = confirm(first, parse(first, monkeypatch)).json()
    second = TestClient(create_app(path))
    assert second.get('/tasks').json()[0]['id'] == task['id']


def test_grounding_removes_invented_quote_and_due():
    task = sample(evidence=[{'field': 'due_at', 'quote': '编造日期', 'page': 1}])
    result = extractor.grounded(Extraction(tasks=[task]), ['实际原文'], False, None)
    assert result.tasks[0].due_at is None
    assert not result.tasks[0].evidence


def test_relative_date_without_baseline():
    task = sample(evidence=[{'field': 'due_at', 'quote': '明天18:00', 'page': 1}])
    result = extractor.grounded(Extraction(tasks=[task]), ['明天18:00'], False, None)
    assert result.tasks[0].due_at is None


@pytest.mark.parametrize('quote', ['2026年11月10日', '2026年11月12日20:00', '2026年11月10日18:00'])
def test_date_must_match_quoted_date_and_time(quote):
    task = sample(evidence=[{'field': 'due_at', 'quote': quote, 'page': 1}])
    assert extractor.grounded(Extraction(tasks=[task]), [quote], False, None).tasks[0].due_at is None


def test_null_optional_fields_are_empty():
    task = ExtractedTask(title='作业', course=None, submission=None, requirements=None)
    assert task.course == task.submission == task.requirements == ''


def test_update_evidence_allowed_and_grounded():
    task = sample(is_update=True, evidence=[{'field': 'is_update', 'quote': '截止时间提前', 'page': 1}])
    result = extractor.grounded(Extraction(tasks=[task]), ['截止时间提前'], False, None)
    assert result.tasks[0].evidence[0].field == 'is_update'


@pytest.mark.parametrize('payload', [
    {'kind': 'text', 'text': ' '},
    {'kind': 'pdf', 'content_base64': 'not-base64'},
    {'kind': 'pdf', 'content_base64': base64.b64encode(b'not a pdf').decode()},
    {'kind': 'image', 'content_base64': base64.b64encode(b'not an image').decode()},
])
def test_invalid_materials(payload):
    with pytest.raises(HTTPException):
        extractor.material_pages(MaterialInput(**payload))


def test_no_key_does_not_return_demo(monkeypatch):
    monkeypatch.setenv('MODEL_API_KEY', '')
    with pytest.raises(HTTPException) as error:
        asyncio.run(extractor.extract(MaterialInput(text='请交作业')))
    assert error.value.status_code == 503


def test_timeout_is_actionable(monkeypatch):
    for key in ('MODEL_BASE_URL', 'MODEL_NAME', 'MODEL_API_KEY'):
        monkeypatch.setenv(key, 'test')
    monkeypatch.setattr(httpx.AsyncClient, 'post', AsyncMock(side_effect=httpx.ReadTimeout('timeout')))
    with pytest.raises(HTTPException) as error:
        asyncio.run(extractor.extract(MaterialInput(text='请交作业')))
    assert error.value.status_code == 504


def req(**kwargs):
    return PlanInput.model_validate({'start': '2026-11-07T18:00:00+08:00',
        'available': [{'start': '2026-11-07T18:00:00+08:00', 'end': '2026-11-07T20:00:00+08:00'}], **kwargs})


def task(id='a', minutes=120, due='2026-11-07T20:00:00+08:00'):
    return {'id': id, 'title': id, 'course': '通信原理', 'estimated_minutes': minutes, 'due_at': due}


def test_schedule_no_overlap_and_conserves_work():
    request = req(blocked=[{'start': '2026-11-07T18:30:00+08:00', 'end': '2026-11-07T19:00:00+08:00'}])
    result = generate_plan([task()], request)
    assert len(result['slots']) == 3
    assert result['unassigned'][0]['minutes'] == 30
    for slot in result['slots']:
        assert not (slot['start'] < '2026-11-07T19:00:00+08:00' and slot['end'] > '2026-11-07T18:30:00+08:00')


def test_overlapping_availability_not_double_counted():
    request = req(available=[{'start': '2026-11-07T18:00:00+08:00', 'end': '2026-11-07T19:00:00+08:00'}] * 2)
    result = generate_plan([task()], request)
    assert len(result['slots']) == 2
    assert result['unassigned'][0]['minutes'] == 60


def test_earliest_deadline_first_and_missing_due():
    result = generate_plan([task('late'), task('early', 30, '2026-11-07T18:30:00+08:00'), task('unknown', 30, None)], req())
    assert result['slots'][0]['task_id'] == 'early'
    assert any(r['task_id'] == 'unknown' and r['minutes'] == 30 for r in result['unassigned'])


def test_completed_and_past_tasks_not_scheduled():
    result = generate_plan([task() | {'completed': True}, task('past', 30, '2026-11-06T20:00:00+08:00')], req())
    assert not result['slots']
    assert result['unassigned'][0]['reason'] == '已超过截止时间'


def test_reschedule_marks_changed_slots():
    first = generate_plan([task('a', 30)], req())
    second = generate_plan([task('a', 30)], req(), first['slots'])
    assert not second['slots'][0]['changed']
    third = generate_plan([task('a', 30)], req(blocked=[{'start': '2026-11-07T18:00:00+08:00', 'end': '2026-11-07T18:30:00+08:00'}]), first['slots'])
    assert third['slots'][0]['changed']


def test_unaligned_start_and_deadline():
    result = generate_plan([task('a', 120, '2026-11-07T19:15:00+08:00')], req(start='2026-11-07T18:01:00+08:00'))
    assert [s['start'] for s in result['slots']] == ['2026-11-07T18:30:00+08:00']
    assert result['unassigned'][0]['minutes'] == 90

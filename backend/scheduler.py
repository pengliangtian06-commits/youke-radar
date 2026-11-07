from datetime import datetime, timedelta

from .models import PlanInput, aware


def generate_plan(tasks: list[dict], request: PlanInput, previous: list[dict] | None = None):
    """EDF over the union of availability; half-open intervals, always 30-minute slots."""
    start = request.start
    horizon = start + timedelta(days=7)
    minute = start.replace(second=0, microsecond=0)
    if minute < start:
        minute += timedelta(minutes=1)
    minute += timedelta(minutes=(-minute.minute) % 30)
    merged = []
    for window in sorted(request.available, key=lambda w: w.start):
        a, b = max(start, window.start), min(horizon, window.end)
        if a >= b:
            continue
        if merged and a <= merged[-1][1]:
            merged[-1] = (merged[-1][0], max(b, merged[-1][1]))
        else:
            merged.append((a, b))
    slots = []
    while minute + timedelta(minutes=30) <= horizon:
        end = minute + timedelta(minutes=30)
        if any(a <= minute and end <= b for a, b in merged) and not any(
            minute < b.end and end > b.start for b in request.blocked
        ):
            slots.append((minute, end))
        minute = end
    output, unassigned = [], []
    old = {(s['task_id'], s['start']) for s in (previous or [])}
    ordered = sorted((t for t in tasks if not t.get('completed')), key=lambda t: (
        aware(datetime.fromisoformat(t['due_at'])) if t.get('due_at') else horizon + timedelta(days=1), t['id']))
    for task in ordered:
        remaining = task['estimated_minutes']
        due = aware(datetime.fromisoformat(task['due_at'])) if task.get('due_at') else None
        if due is None:
            unassigned.append({'task_id': task['id'], 'title': task['title'], 'minutes': remaining, 'reason': '截止时间待确认'})
            continue
        for a, b in list(slots):
            if remaining == 0:
                break
            if b <= due:
                output.append({'task_id': task['id'], 'title': task['title'], 'course': task['course'],
                               'start': a.isoformat(), 'end': b.isoformat(),
                               'changed': bool(previous is not None and (task['id'], a.isoformat()) not in old),
                               'reason': '按截止时间优先安排，已避开课程及不可用时段'})
                slots.remove((a, b))
                remaining -= 30
        if remaining:
            unassigned.append({'task_id': task['id'], 'title': task['title'], 'minutes': remaining,
                               'reason': '已超过截止时间' if due <= start else '未来七天内、截止前的可用时间不足'})
    output.sort(key=lambda s: s['start'])
    conflicts = sum(a['end'] > b['start'] for a, b in zip(output, output[1:]))
    conflicts += sum(aware(datetime.fromisoformat(s['start'])) < block.end and
                     aware(datetime.fromisoformat(s['end'])) > block.start
                     for s in output for block in request.blocked)
    return {'slots': output, 'unassigned': unassigned, 'conflicts': conflicts}

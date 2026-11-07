import json
import sqlite3
from contextlib import contextmanager
from pathlib import Path


class Store:
    def __init__(self, path: str):
        self.path = path
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        with self.connect() as db:
            db.executescript('''
                CREATE TABLE IF NOT EXISTS records (kind TEXT, id TEXT, value TEXT NOT NULL,
                    PRIMARY KEY(kind,id));
                CREATE TABLE IF NOT EXISTS history (task_id TEXT, version INTEGER, value TEXT NOT NULL,
                    PRIMARY KEY(task_id,version));
            ''')

    @contextmanager
    def connect(self):
        db = sqlite3.connect(self.path, timeout=15)
        try:
            with db:
                yield db
        finally:
            db.close()

    def get(self, kind, id, db=None):
        if db is None:
            with self.connect() as conn:
                return self.get(kind, id, conn)
        row = db.execute('SELECT value FROM records WHERE kind=? AND id=?', (kind, id)).fetchone()
        return json.loads(row[0]) if row else None

    def put(self, kind, id, value, db=None):
        if db is None:
            with self.connect() as conn:
                return self.put(kind, id, value, conn)
        db.execute('INSERT OR REPLACE INTO records VALUES (?,?,?)', (kind, id, json.dumps(value, ensure_ascii=False)))

    def all(self, kind):
        with self.connect() as db:
            return [json.loads(r[0]) for r in db.execute('SELECT value FROM records WHERE kind=? ORDER BY rowid', (kind,))]

    def history(self, task_id):
        with self.connect() as db:
            return [json.loads(r[0]) for r in db.execute('SELECT value FROM history WHERE task_id=? ORDER BY version DESC', (task_id,))]

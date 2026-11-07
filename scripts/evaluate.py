"""Run real-provider evaluation without touching user task records."""
import asyncio
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from dotenv import load_dotenv
load_dotenv(ROOT / '.env')
from backend.evaluation import evaluate
from backend.extractor import extract

async def main():
    result = await evaluate(extract)
    destination = ROOT / 'reports' / 'model-evaluation.json'
    destination.parent.mkdir(exist_ok=True)
    destination.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps({k: v for k, v in result.items() if k != 'cases'}, ensure_ascii=False))

asyncio.run(main())

"""Export configs, prompts, grammars and dev data into a bundle the iOS app (and pe-replay) reads.

Usage: python harness/export_ios_bundle.py [--out ios/Bundle]

The YAML configs stay the single source of truth. Notes: the app retrieves and builds the prompt
itself (so retrieval is measured on the phone), from the system prompt and settings exported here.
Calendar: prompts are rendered here with Disha's user_message() and the fixed-date chat template,
so the phone only generates; raw outputs are parsed and scored on the Mac
(harness/score_ios_calendar.py). C3 calendar shares C1's prompt and grammar, so C1's raw outputs
also serve C3 once verified.

Models are not bundled (2 GB). Put them in the app's Documents folder with Finder:
  Llama-3.2-3B-Instruct-Q4_K_M.gguf  and  embed/bge-small-en-v1.5-q8_0.gguf
"""
import argparse
import json
import shutil
from collections import defaultdict
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

from chat_prompt import render_llama32
from config import load_config
from io_utils import read_jsonl, write_jsonl
from run_calendar import user_message as calendar_user_message

ROOT = Path(__file__).resolve().parents[1]
LLAMA_CPP = "b12387"  # ios/fetch_llama.sh; same commit as llama-cpp-python 0.3.37


def gate_ids(items, key, n=10):
    """Round-robin over groups (first slice for notes, action for calendar), so the 10 gate items
    cover every kind of item."""
    groups = defaultdict(list)
    for it in items:
        groups[key(it)].append(it["id"])
    order, out = sorted(groups), []
    while len(out) < n and any(groups.values()):
        for g in order:
            if groups[g] and len(out) < n:
                out.append(groups[g].pop(0))
    return out


def notes_spec(cfg_name):
    cfg = load_config(ROOT / "configs" / f"{cfg_name}.yaml")
    r = cfg["notes_retrieval"]
    spec = {
        "name": f"{cfg_name}_notes", "config": cfg_name, "task": "notes",
        "system_prompt": (ROOT / cfg["prompts"]["notes"]).read_text().strip(),
        "grammar": (ROOT / cfg["grammars"]["notes"]).read_text() if cfg.get("constrained_decoding") else None,
        "max_tokens": 256, "context_tokens": cfg["local_model"]["context_tokens"],
        "items": "notes_dev.jsonl", "corpus": "notes_corpus.jsonl",
        "retrieval": {"method": r["method"], "top_k": r["top_k"]},
    }
    if r["method"] == "hybrid":
        e = r["embedding_model"]
        spec["retrieval"].update(rrf_k=r.get("rrf_k", 60), bm25_candidates=r.get("bm25_candidates", 10),
                                 embedding_file=str(Path(e["file"]).relative_to("models")),
                                 query_prefix=e.get("query_prefix", ""), doc_prefix=e.get("doc_prefix", ""))
    return spec


def calendar_spec(cfg_name, out, items):
    cfg = load_config(ROOT / "configs" / f"{cfg_name}.yaml")
    system = (ROOT / cfg["prompts"]["calendar"]).read_text().strip()
    rows = []
    for it in items:
        ref = datetime.fromisoformat(it["reference_time"]).astimezone(ZoneInfo(it["tz"]))
        rows.append({"id": it["id"], "prompt": render_llama32(system, calendar_user_message(it), ref)})
    fname = f"calendar_{cfg_name}_prompts.jsonl"
    write_jsonl(out / fname, rows)
    return {
        "name": f"{cfg_name}_calendar", "config": cfg_name, "task": "calendar", "system_prompt": None,
        "grammar": (ROOT / cfg["grammars"]["calendar"]).read_text() if cfg.get("constrained_decoding") else None,
        "max_tokens": 160, "context_tokens": cfg["local_model"]["context_tokens"],
        "items": fname, "corpus": None, "retrieval": None,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=str(ROOT / "ios/Bundle"))
    a = ap.parse_args()
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    for f in ["notes_dev.jsonl", "notes_corpus.jsonl"]:
        shutil.copy(ROOT / "data/dev" / f, out / f)
    notes_items = read_jsonl(ROOT / "data/dev/notes_dev.jsonl")
    cal_items = read_jsonl(ROOT / "data/dev/calendar_dev.jsonl")
    base = load_config(ROOT / "configs/_base.yaml")["local_model"]
    manifest = {
        "model_file": Path(base["file"]).name, "model_sha256": base["sha256"].split()[0], "llama_cpp": LLAMA_CPP,
        "gate_ids": {"notes": gate_ids(notes_items, lambda it: it["slice"][0]),
                     "calendar": gate_ids(cal_items, lambda it: it["gold"]["action"])},
        "runs": [notes_spec(c) for c in ["C0", "C1", "C2"]] + [calendar_spec(c, out, cal_items) for c in ["C0", "C1"]],
    }
    (out / "manifest.json").write_text(json.dumps(manifest, indent=1, ensure_ascii=False))
    print(f"Wrote {out}: runs {[r['name'] for r in manifest['runs']]}")
    print("Gate items:", manifest["gate_ids"])


if __name__ == "__main__":
    main()

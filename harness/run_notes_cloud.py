"""Cloud baseline for notes: Gemini on the same items, the same C2 retrieved notes, the same prompt.

  python harness/run_notes_cloud.py --config configs/C2.yaml --out results/cloud_notes_dev

Writes the same _pred.jsonl / _trajectory.jsonl as run_notes.py (plus cloud fields).
"""
import argparse
from datetime import datetime
from pathlib import Path

import yaml

from config import load_config
from io_utils import read_jsonl, write_jsonl
from retrieval import build_retriever
from run_calendar import GeminiModel
from run_notes import is_abstain, parse_output, user_message


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", default="configs/C2.yaml")
    ap.add_argument("--items", default="data/dev/notes_dev.jsonl")
    ap.add_argument("--corpus", default="data/dev/notes_corpus.jsonl")
    ap.add_argument("--cloud-config", default="configs/cloud.yaml")
    ap.add_argument("--out", required=True)
    ap.add_argument("--max-tokens", type=int, default=256)   # as run_notes.py
    ap.add_argument("--timeout-s", type=float, default=60)
    a = ap.parse_args()
    root = Path(__file__).resolve().parents[1]
    cfg = load_config(a.config)
    k = cfg["notes_retrieval"]["top_k"]
    items = read_jsonl(a.items)
    index = build_retriever(cfg, a.corpus, root)
    system = (root / cfg["prompts"]["notes"]).read_text().strip()
    model = GeminiModel(yaml.safe_load((root / a.cloud_config).read_text()), a.timeout_s, a.max_tokens, structured=False)
    preds, traj = [], []
    for i, it in enumerate(items, 1):
        hits = index.search(it["question"], k=k)
        raw, info = model(system, user_message(it, hits), datetime.fromisoformat(it["reference_time"]))
        answer, cits, ok = parse_output(raw)
        abst = is_abstain(answer)
        retrieved = [h.note_id for h in hits]
        gold = set(it["gold"]["support"])
        p = {"id": it["id"], "answer": answer, "citations": cits, "abstained": abst, "format_ok": ok}
        if info.get("error"):
            p["error"] = info["error"]
        preds.append(p)
        traj.append({"id": it["id"], "config": "cloud", "retrieved": [{"note_id": h.note_id, "score": round(h.score, 4)} for h in hits],
                     "retrieval_hit": bool(gold & set(retrieved)) if gold else None, "format_ok": ok,
                     "decision": "abstain" if abst else "answer", "raw_output": raw, **info})
        print(f"[{i}/{len(items)}] {it['id']} abstain={abst} ok={ok} {answer[:60]!r}", flush=True)
    write_jsonl(a.out + "_pred.jsonl", preds)
    write_jsonl(a.out + "_trajectory.jsonl", traj)
    cost = sum(t.get("cost_usd") or 0 for t in traj)
    print(f"Errors: {sum(bool(p.get('error')) for p in preds)}. Format valid: {sum(p['format_ok'] for p in preds)}/60. Cost ${cost:.4f}. "
          f"Versions: {sorted({str(t.get('model_version')) for t in traj})}")


if __name__ == "__main__":
    main()

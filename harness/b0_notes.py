"""B0 for notes: the non-generative baseline (is a model needed at all?).

Retrieves the top-3 notes with BM25 (the same retrieval C0 and C1 use, so C0 vs B0 isolates the
model). B0 cannot write an answer, so it returns the best-matching sentence of the top note as a
verbatim quote. If the top BM25 score is below the abstain threshold, it answers
"the notes don't say". The threshold is set on the dev pilot only (--tune) and stored in
configs/B0.yaml.

Usage:
  python harness/b0_notes.py --tune                       # pick the threshold on dev, print it
  python harness/b0_notes.py --out results/B0_notes_dev   # run with the threshold in configs/B0.yaml
"""
import argparse
import re
import time
from pathlib import Path

import yaml

from io_utils import read_jsonl, write_jsonl
from metrics import abstention_report, print_reports, retrieval_report
from retrieval import BM25Index, query_terms

ABSTAIN = "the notes don't say"
ABBREV = re.compile(r"\b(Dr|Mrs|Mr|Ms|Prof|St|Ave|Apt|No)\.")


def sentences(text):
    protected = ABBREV.sub(lambda m: m.group(1) + "<DOT>", text)
    parts = re.split(r"(?<=[.!?])\s+", protected)
    return [p.replace("<DOT>", ".").strip() for p in parts if p.strip()]


def best_sentence(body, question):
    terms = [t[:5] for t in query_terms(question)]  # crude prefix match stands in for stemming
    def overlap(s):
        words = re.findall(r"[a-z0-9]+", s.lower())
        return sum(any(w.startswith(t) for w in words) for t in terms)
    sents = sentences(body)
    return max(sents, key=overlap)  # ties keep the first sentence


def run(items, index, threshold, k=3):
    preds, traj = [], []
    for it in items:
        t0 = time.perf_counter()
        hits = index.search(it["question"], k=k)
        top = hits[0].score if hits else 0.0
        if not hits or top < threshold:
            pred = {"id": it["id"], "answer": ABSTAIN, "citations": [], "abstained": True}
        else:
            quote = best_sentence(hits[0].body, it["question"])
            pred = {"id": it["id"], "answer": quote,
                    "citations": [{"note_id": hits[0].note_id, "quote": quote}], "abstained": False}
        gold = set(it["gold"]["support"])
        retrieved = [h.note_id for h in hits]
        traj.append({
            "id": it["id"], "config": "B0",
            "retrieved": [{"note_id": h.note_id, "score": round(h.score, 4)} for h in hits],
            "retrieval_hit": bool(gold & set(retrieved)) if gold else None,
            "quote_from_retrieved": all(c["note_id"] in retrieved for c in pred["citations"]),
            "decision": "abstain" if pred["abstained"] else "answer",
            "latency_ms": round((time.perf_counter() - t0) * 1000, 3),
        })
        preds.append(pred)
    return preds, traj


def tune_threshold(items, index, k=3):
    """Pick the abstain threshold that best separates unanswerable from answerable items
    (balanced accuracy), using only the top BM25 score. Dev pilot only."""
    tops = []
    for it in items:
        hits = index.search(it["question"], k=k)
        tops.append((hits[0].score if hits else 0.0, it["gold"]["answerable"] is False))
    candidates = sorted({0.0} | {s for s, _ in tops})
    def bal_acc(t):
        tpr = sum(s < t for s, u in tops if u) / max(1, sum(u for _, u in tops))
        tnr = sum(s >= t for s, u in tops if not u) / max(1, sum(not u for _, u in tops))
        return (tpr + tnr) / 2
    # Midpoint between neighbouring scores, so the threshold isn't sitting on a dev item.
    mids = [0.0] + [(a + b) / 2 for a, b in zip(candidates, candidates[1:])]
    best = max(mids, key=lambda t: (bal_acc(t), -t))
    return best, bal_acc(best), tops


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--items", default="data/dev/notes_dev.jsonl")
    ap.add_argument("--corpus", default="data/dev/notes_corpus.jsonl")
    ap.add_argument("--config", default="configs/B0.yaml")
    ap.add_argument("--threshold", type=float, help="override the config's abstain threshold")
    ap.add_argument("--tune", action="store_true")
    ap.add_argument("--out", help="output prefix, e.g. results/B0_notes_dev")
    a = ap.parse_args()

    items, index = read_jsonl(a.items), BM25Index.from_jsonl(a.corpus)
    k = 3
    if a.tune:
        t, acc, tops = tune_threshold(items, index, k)
        ans = sorted(round(s, 2) for s, u in tops if not u)
        una = sorted(round(s, 2) for s, u in tops if u)
        print(f"Top-1 BM25 scores, unanswerable: {una}")
        print(f"Top-1 BM25 scores, answerable (lowest 12): {ans[:12]}")
        print(f"Best threshold {t:.3f} (balanced accuracy {acc:.2f})")
        return

    cfg = yaml.safe_load(Path(a.config).read_text())
    threshold = a.threshold if a.threshold is not None else cfg["notes"]["abstain_threshold"]
    preds, traj = run(items, index, threshold, k)
    print_reports(retrieval_report(items, {t["id"]: [r["note_id"] for r in t["retrieved"]] for t in traj}, k),
                  abstention_report(items, {p["id"]: p["abstained"] for p in preds}), k)
    if a.out:
        write_jsonl(a.out + "_pred.jsonl", preds)
        write_jsonl(a.out + "_trajectory.jsonl", traj)
        print(f"Wrote {a.out}_pred.jsonl and {a.out}_trajectory.jsonl")


if __name__ == "__main__":
    main()

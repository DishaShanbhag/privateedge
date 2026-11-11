"""Score calendar predictions against gold labels, following conventions.md.

Usage:
  python eval/score_calendar.py --gold data/dev/calendar_dev.jsonl --pred results/C0_calendar_dev.jsonl [--out scores.csv]

An event or reminder is correct only if action, start (exact instant and offset) and, for events,
duration match, and the title contains every gold key term. A clarify item is correct only if the
system clarifies and names at least one gold missing field. Acting on a clarify item, or clarifying
on a complete item, is wrong. Missing predictions count as wrong.
"""
import argparse
import csv
import json
from collections import defaultdict
from datetime import datetime


def load(path):
    with open(path) as f:
        return {r["id"]: r for r in (json.loads(line) for line in f if line.strip())}


def same_time(a, b):
    """Exact match on instant and on written offset."""
    if not a or not b:
        return False
    da, db = datetime.fromisoformat(a), datetime.fromisoformat(b)
    return da == db and da.utcoffset() == db.utcoffset()


def score_item(gold, pred):
    if pred is None:
        return 0, "missing"
    g = gold["gold"]
    if g["action"] == "clarify":
        if pred.get("action") != "clarify":
            return 0, "acted_on_clarify"
        if not set(pred.get("fields", [])) & set(g["fields"]):
            return 0, "wrong_clarify_field"
        return 1, "ok"
    if pred.get("action") == "clarify":
        return 0, "unneeded_clarify"
    if pred.get("action") != g["action"]:
        return 0, "wrong_action"
    if not same_time(pred.get("start"), g["start"]):
        return 0, "wrong_time"
    if g["action"] == "event" and pred.get("duration_min") != g.get("duration_min", 60):
        return 0, "wrong_duration"
    title = pred.get("title", "").lower()
    if not all(t.lower() in title for t in g.get("title_terms", [])):
        return 0, "missing_title_term"
    return 1, "ok"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--gold", required=True)
    ap.add_argument("--pred", required=True)
    ap.add_argument("--out")
    a = ap.parse_args()

    gold, pred = load(a.gold), load(a.pred)
    rows, by_slice = [], defaultdict(list)
    for iid, g in gold.items():
        s, reason = score_item(g, pred.get(iid))
        rows.append({"id": iid, "score": s, "reason": reason})
        for sl in g.get("slice", ["all"]):
            by_slice[sl].append(s)

    total = sum(r["score"] for r in rows)
    print(f"Calendar accuracy: {total}/{len(rows)} = {100 * total / len(rows):.1f}%")
    for sl, v in sorted(by_slice.items()):
        print(f"  {sl:<12} {sum(v)}/{len(v)}")
    reasons = defaultdict(int)
    for r in rows:
        reasons[r["reason"]] += 1
    print("Outcomes:", dict(reasons))

    if a.out:
        with open(a.out, "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=["id", "score", "reason"])
            w.writeheader()
            w.writerows(rows)


if __name__ == "__main__":
    main()

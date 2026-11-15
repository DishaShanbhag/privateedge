"""Automatic notes metrics that need no human grader.

- Retrieval, on answerable and partial items: hit@k (any gold note retrieved) and all@k
  (every gold note retrieved), per slice.
- Abstention: did the system say "the notes don't say" exactly on the unanswerable items?

These numbers don't replace the 0-2 rubric scores (conventions.md), which human graders assign.
"""
from collections import defaultdict


def retrieval_report(items, retrieved_by_id, k=3):
    by_slice = defaultdict(lambda: [0, 0, 0])  # n, hit, all
    for it in items:
        gold = set(it["gold"]["support"])
        if not gold:
            continue
        got = set(retrieved_by_id.get(it["id"], [])[:k])
        for sl in ["all"] + it["slice"]:
            row = by_slice[sl]
            row[0] += 1
            row[1] += bool(gold & got)
            row[2] += gold <= got
    return {sl: {"n": n, f"hit@{k}": h / n, f"all@{k}": a / n} for sl, (n, h, a) in by_slice.items()}


def abstention_report(items, abstained_by_id):
    tp = fp = fn = tn = 0
    for it in items:
        should = it["gold"]["answerable"] is False
        did = abstained_by_id.get(it["id"], False)
        tp += should and did
        fp += did and not should
        fn += should and not did
        tn += not should and not did
    prec = tp / (tp + fp) if tp + fp else 0.0
    rec = tp / (tp + fn) if tp + fn else 0.0
    return {"abstain_precision": prec, "abstain_recall": rec, "wrongly_abstained": fp,
            "answered_unanswerable": fn, "n_abstained": tp + fp}


def print_reports(ret, abst, k=3):
    print(f"Retrieval (answerable + partial items), top-{k}:")
    order = ["all"] + sorted(s for s in ret if s != "all")
    for sl in order:
        r = ret[sl]
        print(f"  {sl:<14} n={r['n']:<3} hit@{k}={r[f'hit@{k}']:.2f}  all@{k}={r[f'all@{k}']:.2f}")
    print("Abstention:", {k_: round(v, 2) if isinstance(v, float) else v for k_, v in abst.items()})

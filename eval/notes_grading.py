"""Blind 0-2 grading of notes answers (conventions.md, "Notes (0 to 2)").

export: turns every system's notes predictions into one shuffled grading sheet with no system
        names, plus a 20% subset for the second grader and a key that maps rows back to systems.
import: reads the filled sheets, checks the scores, computes Cohen's kappa on the double-graded
        rows, lists disagreements for adjudication, and writes one id,score file per system for
        eval/bootstrap_gap.py --max-score 2.

  python eval/notes_grading.py export --items data/test/notes_test.jsonl --corpus data/test/notes_test_corpus.jsonl \
      --run B0=results/.../B0_pred.jsonl --run C2=... --run cloud=... --out-dir results/raw/grading_test
  python eval/notes_grading.py import --dir results/raw/grading_test \
      --first first_grader.csv --second second_grader.csv [--adjudicated adjudicated.csv] --out-dir results/raw/grading_test

Blindness:
- The sheets show no system names.
- Rows are shuffled, so one question's answers are not next to each other.
- When two systems give the same answer with the same citations to the same question, they share
  one row and one grade. Graders never learn how many systems a row stands for.
- grading_key.json is the only file that links rows to systems. Graders must not open it.

Mechanical scores (the rubric decides them, so they are not graded by hand):
- "the notes don't say" on an unanswerable item scores 2;
- any other answer to an unanswerable item scores 0.
Everything else, including an abstention on an answerable item, is graded by hand.
"""
import argparse
import csv
import json
import math
import random
import re
from collections import Counter, defaultdict
from pathlib import Path

ABSTAIN = "the notes don't say"
SHEET_COLUMNS = ["row_id", "question", "answer", "citations", "cited_notes", "gold_answer", "key_facts",
                 "answerable", "unsupported_part", "score", "comment"]


def read_jsonl(path):
    with open(path) as f:
        return [json.loads(line) for line in f if line.strip()]


def is_abstain(answer):
    return re.sub(r"\s+", " ", (answer or "").lower()).strip().rstrip(".") == ABSTAIN


def _norm(s):
    return re.sub(r"\s+", " ", (s or "")).strip()


def answer_key(pred):
    """Two predictions share a grading row only if the answer and the citations are identical."""
    cits = tuple(sorted((c["note_id"], _norm(c["quote"])) for c in pred.get("citations") or []))
    return (_norm(pred.get("answer")), cits)


def auto_score(item, pred):
    """The two cases the rubric settles mechanically, or None."""
    if item["gold"]["answerable"] is False:
        return (2, "abstained on an unanswerable item") if is_abstain(pred.get("answer")) else \
               (0, "answered an unanswerable item")
    return None


def export(items, corpus, runs, out_dir, seed=0, double_frac=0.2):
    """runs: {system: [pred, ...]}. Writes the sheets and the key; returns a summary dict."""
    items = {it["id"]: it for it in items}
    notes = {n["id"]: n for n in corpus}
    rows = {}          # (item_id, answer_key) -> row
    auto = {}          # system -> {item_id: [score, reason]}
    to_grade = Counter()
    for system, preds in runs.items():
        by_id = {p["id"]: p for p in preds}
        missing = sorted(set(items) - set(by_id))
        if missing:
            raise SystemExit(f"{system}: no prediction for {len(missing)} items, e.g. {missing[:3]}")
        for iid, it in items.items():
            p = by_id[iid]
            a = auto_score(it, p)
            if a is not None:
                auto.setdefault(system, {})[iid] = list(a)
                continue
            key = (iid, answer_key(p))
            if key not in rows:
                rows[key] = {"item": it, "pred": p, "systems": []}
            rows[key]["systems"].append(system)
            to_grade[system] += 1

    rng = random.Random(seed)
    ordered = list(rows.values())
    rng.shuffle(ordered)
    sheet, key = [], {}
    for n, r in enumerate(ordered, 1):
        rid = f"G{n:04d}"
        it, p, g = r["item"], r["pred"], r["item"]["gold"]
        cited = []
        for c in p.get("citations") or []:
            note = notes.get(c["note_id"])
            cited.append(f"[{c['note_id']}] {note['title']}: {note['body']}" if note else f"[{c['note_id']}] (no such note)")
        sheet.append({
            "row_id": rid, "question": it["question"], "answer": p.get("answer", ""),
            "citations": " | ".join(f"{c['note_id']}: \"{c['quote']}\"" for c in p.get("citations") or []),
            "cited_notes": "\n\n".join(cited), "gold_answer": g.get("answer", ""),
            "key_facts": "; ".join(g.get("key_facts") or []),
            "answerable": {True: "yes", False: "no", "partial": "partial"}[g["answerable"]],
            "unsupported_part": g.get("unsupported_part", ""), "score": "", "comment": "",
        })
        key[rid] = {"item_id": it["id"], "systems": r["systems"]}

    n_second = math.ceil(double_frac * len(sheet)) if sheet else 0
    second_ids = set(rng.sample([s["row_id"] for s in sheet], n_second))
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    _write_csv(out / "grading_sheet_first.csv", sheet)
    _write_csv(out / "grading_sheet_second.csv", [s for s in sheet if s["row_id"] in second_ids])
    (out / "grading_key.json").write_text(json.dumps(
        {"_warning": "Graders must not open this file.", "rows": key, "auto": auto,
         "systems": list(runs), "items": sorted(items), "second_rows": sorted(second_ids)}, indent=1))
    graded_answers = sum(to_grade.values())
    return {"rows_to_grade": len(sheet), "answers_covered_by_rows": graded_answers,
            "auto_scored": sum(len(v) for v in auto.values()), "second_grader_rows": n_second,
            "per_system_to_grade": dict(to_grade)}


def _write_csv(path, rows):
    with open(path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=SHEET_COLUMNS)
        w.writeheader()
        w.writerows(rows)


def read_scores(path, allowed_ids=None):
    """row_id -> score (0, 1 or 2). Refuses blanks, other values and unknown rows."""
    out, bad = {}, []
    with open(path, newline="") as f:
        for r in csv.DictReader(f):
            rid, s = r["row_id"].strip(), (r.get("score") or "").strip()
            if allowed_ids is not None and rid not in allowed_ids:
                bad.append(f"{rid}: not a row of this export")
            elif s not in {"0", "1", "2"}:
                bad.append(f"{rid}: score {s!r} is not 0, 1 or 2")
            else:
                out[rid] = int(s)
    if bad:
        raise SystemExit(f"{path}: {len(bad)} problems, e.g. " + "; ".join(bad[:5]))
    return out


def cohen_kappa(a, b, weights=None, labels=(0, 1, 2)):
    """Cohen's kappa for paired ratings; weights=None (unweighted) or 'quadratic'."""
    n = len(a)
    if n == 0:
        return float("nan")
    k = len(labels)
    idx = {l: i for i, l in enumerate(labels)}
    w = [[(0 if i == j else 1) if weights is None else ((i - j) ** 2) / ((k - 1) ** 2) for j in range(k)]
         for i in range(k)]
    obs = [[0.0] * k for _ in range(k)]
    for x, y in zip(a, b):
        obs[idx[x]][idx[y]] += 1 / n
    pa = [sum(obs[i]) for i in range(k)]
    pb = [sum(obs[i][j] for i in range(k)) for j in range(k)]
    d_obs = sum(w[i][j] * obs[i][j] for i in range(k) for j in range(k))
    d_exp = sum(w[i][j] * pa[i] * pb[j] for i in range(k) for j in range(k))
    return 1.0 if d_exp == 0 else 1 - d_obs / d_exp


def do_import(dir_, first, second, adjudicated=None, out_dir=None, allow_unadjudicated=False):
    key = json.loads((Path(dir_) / "grading_key.json").read_text())
    rows = key["rows"]
    s1 = read_scores(first, set(rows))
    missing = sorted(set(rows) - set(s1))
    if missing:
        raise SystemExit(f"{first}: {len(missing)} rows not graded, e.g. {missing[:5]}")
    s2 = read_scores(second, set(key["second_rows"])) if second else {}
    both = sorted(set(s1) & set(s2))
    kappa = cohen_kappa([s1[r] for r in both], [s2[r] for r in both])
    kappa_q = cohen_kappa([s1[r] for r in both], [s2[r] for r in both], weights="quadratic")
    disagree = [r for r in both if s1[r] != s2[r]]
    adj = read_scores(adjudicated, set(disagree)) if adjudicated else {}
    unresolved = [r for r in disagree if r not in adj]
    out = Path(out_dir or dir_)
    out.mkdir(parents=True, exist_ok=True)
    if unresolved:
        with open(out / "to_adjudicate.csv", "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["row_id", "first_score", "second_score", "score"])
            w.writerows([r, s1[r], s2[r], ""] for r in unresolved)
        if not allow_unadjudicated:
            print(f"kappa {kappa:.3f} (quadratic {kappa_q:.3f}) on {len(both)} double-graded rows; "
                  f"{len(unresolved)} disagreements written to {out / 'to_adjudicate.csv'} for the third grader")
            return {"kappa": kappa, "kappa_quadratic": kappa_q, "n_double": len(both), "unresolved": len(unresolved)}
    final = {r: adj.get(r, s1[r]) for r in rows}

    per_system = defaultdict(dict)
    for rid, info in rows.items():
        for system in info["systems"]:
            per_system[system][info["item_id"]] = final[rid]
    for system, scores in key["auto"].items():
        for iid, (score, _reason) in scores.items():
            per_system[system][iid] = score
    summary = {}
    for system in key["systems"]:
        scores = per_system[system]
        if set(scores) != set(key["items"]):
            raise SystemExit(f"{system}: scores for {len(scores)} of {len(key['items'])} items")
        with open(out / f"{system}_notes_scores.csv", "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["id", "score"])
            w.writerows(sorted(scores.items()))
        summary[system] = sum(scores.values()) / (2 * len(scores))
    print(f"kappa {kappa:.3f} (quadratic {kappa_q:.3f}) on {len(both)} double-graded rows, "
          f"{len(disagree)} disagreements, {len(adj)} adjudicated")
    for system, frac in summary.items():
        print(f"  {system:<10} mean score {2 * frac:.2f} / 2  ({100 * frac:.1f}%)")
    return {"kappa": kappa, "kappa_quadratic": kappa_q, "n_double": len(both), "unresolved": len(unresolved),
            "mean": summary}


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    e = sub.add_parser("export")
    e.add_argument("--items", required=True)
    e.add_argument("--corpus", required=True)
    e.add_argument("--run", action="append", required=True, help="SYSTEM=path/to/_pred.jsonl (repeat)")
    e.add_argument("--out-dir", required=True)
    e.add_argument("--seed", type=int, default=0)
    e.add_argument("--double-frac", type=float, default=0.2)
    i = sub.add_parser("import")
    i.add_argument("--dir", required=True)
    i.add_argument("--first", required=True)
    i.add_argument("--second")
    i.add_argument("--adjudicated")
    i.add_argument("--out-dir")
    i.add_argument("--allow-unadjudicated", action="store_true",
                   help="use the first grader's score where graders disagree (draft numbers only)")
    a = ap.parse_args()
    if a.cmd == "export":
        runs = {}
        for spec in a.run:
            system, _, path = spec.partition("=")
            if not path:
                raise SystemExit(f"--run expects SYSTEM=path, got {spec!r}")
            runs[system] = read_jsonl(path)
        s = export(read_jsonl(a.items), read_jsonl(a.corpus), runs, a.out_dir, a.seed, a.double_frac)
        print(json.dumps(s, indent=1))
    else:
        do_import(a.dir, a.first, a.second, a.adjudicated, a.out_dir, a.allow_unadjudicated)


if __name__ == "__main__":
    main()

"""C3 for notes: code checks on an answer before it reaches the user (Milestone 2, section 4).

An answer passes only if:
  cited        it cites at least one note, and every cited note was among the retrieved notes;
  quote        every quote appears word for word (case and spacing aside) in the note it cites;
  grounded     every number, date word and name in the answer occurs in the cited text
               (grounding "quote": the quotes, as proposed; "note": the whole cited notes);
  retrieval    the top retrieval score clears the dev-set threshold (notes_retrieval_threshold).
Otherwise the system abstains: the answer becomes "the notes don't say". "The notes don't say"
answers pass through unchanged. Partial answers ("... the notes don't say the rest") are checked
on what they do claim.

Offline use on an existing C2 run (C3 = C2's prompt, grammar and retrieval + these checks, so the
generations are identical and need not be re-run):
  python harness/verify_notes.py --run results/C2_notes_dev --sweep          # tune the threshold on dev
  python harness/verify_notes.py --run results/C2_notes_dev --threshold 0 --grounding quote \
      --out results/C3_notes_dev
"""
import argparse
import json
import re
from pathlib import Path

ABSTAIN = "the notes don't say"
MONTHS = ("january february march april may june july august september october november december "
          "jan feb mar apr jun jul aug sep sept oct nov dec").split()
DAYS = ("monday tuesday wednesday thursday friday saturday sunday "
        "mon tue tues wed thu thur thurs fri sat sun").split()
_CANON = {**{m[:3]: m[:3] for m in MONTHS}, **{d[:3]: d[:3] for d in DAYS}}
# Capitalised words that are not names (sentence words, units, pronouns).
NOT_NAMES = set("""
the a an and or but if it its is are was were be i you he she we they my your his her our their this that these
those there here on in at to for from of by with without about after before during until next last every each
yes no not one two three both either neither some any all also only just then so as when where what which who how
notes note say says said according bring call text email pay take use see go buy get keep check ask tell
""".split())
_WORD = re.compile(r"[A-Za-z][A-Za-z'.\-]*[A-Za-z]|[A-Za-z]")


def _norm(s):
    return re.sub(r"\s+", " ", (s or "").lower()).strip()


def is_abstain(answer):
    return _norm(answer).rstrip(".") == ABSTAIN


def numbers(text):
    """Digit runs, with thousands separators removed: "$1,200" -> "1200"; "9am-12pm" -> 9, 12."""
    return re.findall(r"\d+", re.sub(r"(?<=\d),(?=\d{3})", "", text or ""))


def date_words(text):
    """Month and weekday names, as their first three letters."""
    out = set()
    for w in re.findall(r"[a-z]+", (text or "").lower()):
        if w in MONTHS or w in DAYS:
            out.add(_CANON.get(w[:3], w[:3]))
    return out


def names(text):
    """Capitalised words not at the start of a sentence (and not ordinary words, months or days)."""
    out = set()
    for sent in re.split(r"(?<=[.!?;:])\s+|\n+", text or ""):
        words = _WORD.findall(sent)
        for w in words[1:]:
            bare = w.strip(".").lower()
            if w[0].isupper() and bare not in NOT_NAMES and bare not in MONTHS and bare not in DAYS and len(bare) > 1:
                out.add(bare)
    return out


def claims(answer):
    """The checkable entities an answer asserts. The "the notes don't say ..." part asserts nothing."""
    text = re.sub(r"(?i)the notes don'?t say[^.;]*", " ", answer or "")
    return {"numbers": numbers(text), "dates": date_words(text), "names": names(text)}


def check(answer, citations, retrieved, notes, threshold=0.0, grounding="quote"):
    """-> verdict {"ok", "failed": [checks], "details"}. `retrieved`: [{"note_id", "score"}]."""
    if is_abstain(answer):
        return {"ok": True, "failed": [], "details": {}}
    failed, details = [], {}

    def fail(name, why):
        if name not in failed:
            failed.append(name)
        details.setdefault(name, why)

    retrieved_ids = [r["note_id"] for r in retrieved]
    if not citations:
        fail("cited", "no citation")
    for c in citations:
        if c["note_id"] not in retrieved_ids:
            fail("cited", f"{c['note_id']} was not retrieved")
        body = notes.get(c["note_id"], {}).get("body", "")
        if not c["quote"].strip() or _norm(c["quote"]) not in _norm(body):
            fail("quote", f"quote not in {c['note_id']}: {c['quote'][:60]!r}")

    if grounding == "quote":
        source = " ".join(c["quote"] for c in citations)
    else:
        source = " ".join(notes.get(c["note_id"], {}).get("body", "") for c in citations)
    have = {"numbers": set(numbers(source)), "dates": date_words(source), "names": {w for w in re.findall(r"[a-z][a-z'\-]*", _norm(source).replace(".", " "))}}
    cl = claims(answer)
    missing = ([n for n in cl["numbers"] if n not in have["numbers"]]
               + [d for d in cl["dates"] if d not in have["dates"]]
               + [n for n in cl["names"] if not any(n == w or n in w for w in have["names"])])
    if missing:
        fail("grounded", f"not in the cited {grounding}: {sorted(set(missing))}")

    top = max((r["score"] for r in retrieved), default=0.0)
    if top < threshold:
        fail("retrieval", f"top retrieval score {top:.4f} < {threshold}")
    return {"ok": not failed, "failed": failed, "details": details}


# ---------------------------------------------------------------- automatic proxy for tuning

def key_facts_present(answer, facts):
    """Proxy for "correct": every key fact appears in the answer (case, spaces, $ and commas aside).
    Not the 0-2 rubric, which human graders assign; used only to tune and to report verifier
    precision/recall on dev."""
    a = re.sub(r"[\s$,]", "", (answer or "").lower())
    return all(re.sub(r"[\s$,]", "", f.lower()) in a for f in facts)


def proxy_correct(item, pred):
    g = item["gold"]
    if g["answerable"] is False:
        return pred["abstained"]
    if pred["abstained"]:
        return False
    return key_facts_present(pred["answer"], g.get("key_facts") or [])


def apply(items, preds, traj, notes, threshold, grounding):
    """C3 on a C2 run -> (new preds, verdict per id)."""
    by_t = {t["id"]: t for t in traj}
    out, verdicts = [], {}
    for p in preds:
        v = check(p["answer"], p["citations"], by_t[p["id"]]["retrieved"], notes, threshold, grounding)
        verdicts[p["id"]] = v
        out.append(p if v["ok"] else {**p, "answer": ABSTAIN, "citations": [], "abstained": True})
    return out, verdicts


def report(items, before, after, verdicts):
    """Proxy accuracy, abstention, and verifier precision/recall over the answers it saw."""
    gold = {it["id"]: it for it in items}
    b = {p["id"]: p for p in before}
    acc = sum(proxy_correct(gold[p["id"]], p) for p in after) / len(after)
    tp = fp = fn = tn = 0
    for p in before:
        if p["abstained"]:
            continue
        wrong = not proxy_correct(gold[p["id"]], p)
        flagged = not verdicts[p["id"]]["ok"]
        tp += wrong and flagged
        fp += flagged and not wrong
        fn += wrong and not flagged
        tn += not wrong and not flagged
    unans = [i for i in items if i["gold"]["answerable"] is False]
    return {
        "proxy_accuracy": round(acc, 3),
        "abstain_recall": sum(next(p for p in after if p["id"] == i["id"])["abstained"] for i in unans) / len(unans),
        "wrongly_abstained": sum(p["abstained"] and gold[p["id"]]["gold"]["answerable"] is not False for p in after),
        "verifier_flagged_wrong": tp, "verifier_flagged_right": fp, "missed_wrong": fn, "passed_right": tn,
        "verifier_precision": round(tp / (tp + fp), 2) if tp + fp else None,
        "verifier_recall": round(tp / (tp + fn), 2) if tp + fn else None,
        "silent_errors": fn + sum(1 for p in after if not p["abstained"] and gold[p["id"]]["gold"]["answerable"] is False),
        "_before": {pid: b[pid]["abstained"] for pid in b},
    }


def _read(path):
    with open(path) as f:
        return [json.loads(line) for line in f if line.strip()]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run", required=True, help="a C2 notes run prefix, e.g. results/C2_notes_dev")
    ap.add_argument("--items", default="data/dev/notes_dev.jsonl")
    ap.add_argument("--corpus", default="data/dev/notes_corpus.jsonl")
    ap.add_argument("--threshold", type=float, default=0.0)
    ap.add_argument("--grounding", choices=["quote", "note"], default="quote")
    ap.add_argument("--sweep", action="store_true", help="print results over thresholds and both groundings")
    ap.add_argument("--out", help="write <out>_pred.jsonl and <out>_trajectory.jsonl")
    a = ap.parse_args()
    items, preds, traj = _read(a.items), _read(a.run + "_pred.jsonl"), _read(a.run + "_trajectory.jsonl")
    notes = {n["id"]: n for n in _read(a.corpus)}
    base = report(items, preds, preds, {p["id"]: {"ok": True} for p in preds})
    print(f"Before verification ({a.run}): proxy accuracy {base['proxy_accuracy']}, "
          f"wrongly abstained {base['wrongly_abstained']}, silent errors {base['silent_errors']}")
    if a.sweep:
        tops = sorted({max(r["score"] for r in t["retrieved"]) for t in traj})
        for grounding in ("quote", "note"):
            for th in [0.0] + tops:
                after, v = apply(items, preds, traj, notes, th, grounding)
                r = report(items, preds, after, v)
                print(f"grounding={grounding:<5} threshold={th:<7.4f} acc={r['proxy_accuracy']:.3f} "
                      f"wrongly_abstained={r['wrongly_abstained']:<2} silent={r['silent_errors']:<2} "
                      f"P={r['verifier_precision']} R={r['verifier_recall']} "
                      f"(flagged wrong {r['verifier_flagged_wrong']}, flagged right {r['verifier_flagged_right']})")
        return
    after, v = apply(items, preds, traj, notes, a.threshold, a.grounding)
    r = report(items, preds, after, v)
    print({k: val for k, val in r.items() if not k.startswith("_")})
    for p in preds:
        if not v[p["id"]]["ok"]:
            print(f"  flagged {p['id']}: {v[p['id']]['failed']} {list(v[p['id']]['details'].values())[0]}")
    if a.out:
        by_t = {t["id"]: t for t in traj}
        with open(a.out + "_pred.jsonl", "w") as f:
            for p in after:
                f.write(json.dumps(p) + "\n")
        with open(a.out + "_trajectory.jsonl", "w") as f:
            for p0, p1 in zip(preds, after):
                t = {**by_t[p0["id"]], "config": "C3", "pred_before_verify": p0,
                     "verifier": {**v[p0["id"]], "threshold": a.threshold, "grounding": a.grounding},
                     "decision": "abstain" if p1["abstained"] else "answer"}
                f.write(json.dumps(t) + "\n")
        print(f"Wrote {a.out}_pred.jsonl and {a.out}_trajectory.jsonl")


if __name__ == "__main__":
    main()

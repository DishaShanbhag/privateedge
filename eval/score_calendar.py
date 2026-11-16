"""Score calendar/action predictions against gold labels, following conventions.md.

Usage:
  python eval/score_calendar.py --gold data/dev/calendar_dev.jsonl --pred results/C0_calendar_dev_pred.jsonl [--out scores.csv]

Exact match (binary, per item):
  - event / reminder: action, start (exact instant AND written offset) and, for events, duration
    match; the title holds every gold key term and no unsupported word.
  - expense: amount, currency and date match; the description holds every key term and no
    unsupported word.
  - none: the system returns none.
  - clarify: the system clarifies and names at least one gold field.
  - schema-invalid output (`schema_valid: false`) and missing predictions are wrong.

Also reported: schema-valid rate; per-field accuracy (action, date, time, duration, title,
amount); results per slice; and accuracy on two item sets, "events and reminders" (as proposed in
Milestone 2, with their clarify items) and "all actions". --out writes id,score,reason plus one
0/1 column per subset, so bootstrap_gap.py can take either.

Silent errors (always reported): the system ACTED (event, reminder or expense) and was wrong, with
no clarify to warn the user. With --trajectory from a C3 run, also verifier precision and recall:
of the acted outputs before verification, how many wrong ones the verifier flagged (recall) and
how many of its flags were on wrong ones (precision).
"""
import argparse
import csv
import json
import re
from collections import defaultdict
from datetime import datetime
from difflib import SequenceMatcher

# Words that never count as an invented entity in a title or description.
FUNCTION_WORDS = frozenset("""
a an the and or with w w/ for of on at to in into my me our your his her their from by about re
up out back this that is are be it i we you
""".split())
DATEWORDS = re.compile(
    r"^(\d+(:\d+)?(am|pm|a|p)?|\d+(st|nd|rd|th)|mon|tue|tues|wed|thu|thur|thurs|fri|sat|sun|"
    r"(mon|tues|wednes|thurs|fri|satur|sun)day|today|tonight|tomorrow|morning|afternoon|evening|night|"
    r"jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec|"
    r"january|february|march|april|june|july|august|september|october|november|december)$")


def load(path):
    with open(path) as f:
        return {r["id"]: r for r in (json.loads(line) for line in f if line.strip())}


def same_time(a, b):
    """Exact match on instant and on written offset."""
    if not a or not b:
        return False
    try:
        da, db = datetime.fromisoformat(a), datetime.fromisoformat(b)
    except ValueError:
        return False
    return da == db and da.utcoffset() == db.utcoffset()


def _words(text):
    return re.findall(r"[a-z0-9][a-z0-9':/]*", (text or "").lower())


def _matches(word, msg_words):
    for m in msg_words:
        if word == m or word.rstrip("s") == m.rstrip("s"):
            return True
        if len(word) >= 4 and len(m) >= 3 and SequenceMatcher(None, word, m).ratio() >= 0.8:
            return True  # small typos: "dinnr" -> "dinner"
    return False


def unsupported_words(title, message):
    """Title words that are not function, date or time words and match no message word."""
    msg = _words(message)
    return [w for w in _words(title)
            if w not in FUNCTION_WORDS and not DATEWORDS.match(w) and not _matches(w, msg)]


def _terms_ok(text, terms):
    t = (text or "").lower()
    return all(term.lower() in t for term in terms)


def score_item(gold, pred):
    """-> (0 or 1, reason)."""
    if pred is None:
        return 0, "missing"
    if pred.get("schema_valid") is False or pred.get("action") is None:
        return 0, "schema_invalid"
    g, act = gold["gold"], pred.get("action")
    msg = gold.get("message", "")
    if g["action"] == "clarify":
        if act != "clarify":
            return 0, "acted_on_clarify"
        if not set(pred.get("fields", [])) & set(g["fields"]):
            return 0, "wrong_clarify_field"
        return 1, "ok"
    if act == "clarify":
        return 0, "unneeded_clarify"
    if g["action"] == "none":
        return (1, "ok") if act == "none" else (0, "acted_on_none")
    if act != g["action"]:
        return 0, "wrong_action"
    if g["action"] == "expense":
        if pred.get("amount") != g["amount"]:
            return 0, "wrong_amount"
        if pred.get("currency") != g["currency"]:
            return 0, "wrong_currency"
        if pred.get("date") != g["date"]:
            return 0, "wrong_date"
        if not _terms_ok(pred.get("description"), g.get("description_terms", [])):
            return 0, "missing_title_term"
        if unsupported_words(pred.get("description"), msg):
            return 0, "unsupported_title_word"
        return 1, "ok"
    if not same_time(pred.get("start"), g["start"]):
        return 0, "wrong_time"
    if g["action"] == "event" and pred.get("duration_min") != g.get("duration_min", 60):
        return 0, "wrong_duration"
    if not _terms_ok(pred.get("title"), g.get("title_terms", [])):
        return 0, "missing_title_term"
    if unsupported_words(pred.get("title"), msg):
        return 0, "unsupported_title_word"
    return 1, "ok"


def _local_date(iso):
    try:
        return datetime.fromisoformat(iso).date().isoformat()
    except (TypeError, ValueError):
        return None


def _wall_and_offset(iso):
    try:
        d = datetime.fromisoformat(iso)
        return d.strftime("%H:%M"), d.utcoffset()
    except (TypeError, ValueError):
        return None


def field_results(gold, pred):
    """Per-field correctness for the fields this gold item has: {field: 0/1}.
    A wrong action makes every value field wrong (the value was never produced)."""
    g, p = gold["gold"], pred or {}
    same = p.get("schema_valid") is not False and p.get("action") == g["action"]
    out = {"action": int(same)}
    if g["action"] in ("event", "reminder"):
        out["date"] = int(same and _local_date(p.get("start")) == _local_date(g["start"]))
        out["time"] = int(same and _wall_and_offset(p.get("start")) == _wall_and_offset(g["start"]))
        out["title"] = int(same and _terms_ok(p.get("title"), g.get("title_terms", []))
                           and not unsupported_words(p.get("title"), gold.get("message", "")))
        if g["action"] == "event":
            out["duration"] = int(same and p.get("duration_min") == g.get("duration_min", 60))
    elif g["action"] == "expense":
        out["date"] = int(same and p.get("date") == g["date"])
        out["amount"] = int(same and p.get("amount") == g["amount"] and p.get("currency") == g["currency"])
        out["title"] = int(same and _terms_ok(p.get("description"), g.get("description_terms", []))
                           and not unsupported_words(p.get("description"), gold.get("message", "")))
    return out


def in_events_reminders(gold):
    """The task as proposed in Milestone 2: events, reminders, and the clarify items about them."""
    g = gold["gold"]
    return g["action"] in ("event", "reminder") or (g["action"] == "clarify" and g.get("intended") != "expense")


def score_all(gold, pred):
    rows, by_slice, fields = [], defaultdict(list), defaultdict(list)
    for iid, g in gold.items():
        s, reason = score_item(g, pred.get(iid))
        rows.append({"id": iid, "score": s, "reason": reason, "events_reminders": int(in_events_reminders(g))})
        for sl in g.get("slice") or ["all"]:
            by_slice[sl].append(s)
        for f, v in field_results(g, pred.get(iid)).items():
            fields[f].append(v)
    valid = sum(1 for iid in gold if iid in pred and pred[iid].get("schema_valid") is not False
                and pred[iid].get("action") is not None)
    return rows, by_slice, fields, valid


ACTS = ("event", "reminder", "expense")


def silent_errors(gold, pred):
    return sum(1 for iid, g in gold.items()
               if (pred.get(iid) or {}).get("action") in ACTS and score_item(g, pred.get(iid))[0] == 0)


def verifier_report(gold, traj):
    """Verifier precision/recall over outputs that acted before verification."""
    tp = fp = fn = tn = 0
    for t in traj:
        before, v = t.get("pred_before_verify"), t.get("verifier")
        if not before or before.get("action") not in ACTS or v is None or t["id"] not in gold:
            continue
        wrong = score_item(gold[t["id"]], before)[0] == 0
        flagged = not v["ok"]
        tp += wrong and flagged
        fp += flagged and not wrong
        fn += wrong and not flagged
        tn += not wrong and not flagged
    prec = tp / (tp + fp) if tp + fp else None
    rec = tp / (tp + fn) if tp + fn else None
    return {"flagged_wrong": tp, "flagged_right": fp, "missed_wrong": fn, "passed_right": tn,
            "precision": prec, "recall": rec}


def _pct(v):
    return f"{sum(v)}/{len(v)} = {100 * sum(v) / len(v):.1f}%" if v else "n/a"


def report(rows, by_slice, fields, valid, n, silent=0):
    er = [r["score"] for r in rows if r["events_reminders"]]
    allv = [r["score"] for r in rows]
    print(f"Calendar accuracy, all actions:         {_pct(allv)}")
    print(f"Calendar accuracy, events and reminders: {_pct(er)}")
    print(f"Schema-valid outputs: {valid}/{n}")
    print(f"Silent errors (acted and wrong): {silent}/{n}")
    print("Per-field accuracy (over gold items that have the field):")
    for f in ("action", "date", "time", "duration", "title", "amount"):
        if fields.get(f):
            print(f"  {f:<9} {_pct(fields[f])}")
    print("Per slice:")
    for sl, v in sorted(by_slice.items()):
        print(f"  {sl:<10} {_pct(v)}")
    reasons = defaultdict(int)
    for r in rows:
        reasons[r["reason"]] += 1
    print("Outcomes:", dict(sorted(reasons.items(), key=lambda kv: -kv[1])))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--gold", required=True)
    ap.add_argument("--pred", required=True)
    ap.add_argument("--out", help="per-item CSV: id,score,reason,events_reminders")
    ap.add_argument("--trajectory", help="a C3 _trajectory.jsonl, for verifier precision and recall")
    a = ap.parse_args()

    gold, pred = load(a.gold), load(a.pred)
    rows, by_slice, fields, valid = score_all(gold, pred)
    report(rows, by_slice, fields, valid, len(gold), silent_errors(gold, pred))
    if a.trajectory:
        with open(a.trajectory) as f:
            vr = verifier_report(gold, [json.loads(line) for line in f if line.strip()])
        fmt = lambda x: "n/a" if x is None else f"{x:.2f}"
        print(f"Verifier: precision {fmt(vr['precision'])}, recall {fmt(vr['recall'])}  "
              f"(flagged wrong {vr['flagged_wrong']}, flagged right {vr['flagged_right']}, "
              f"missed wrong {vr['missed_wrong']}, passed right {vr['passed_right']})")
    if a.out:
        with open(a.out, "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=["id", "score", "reason", "events_reminders"])
            w.writeheader()
            w.writerows(rows)


if __name__ == "__main__":
    main()

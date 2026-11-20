"""B0 for calendar/actions: the non-generative baseline (is a model needed at all?). Runs on a Mac.

Pipeline, per message:
  1. Find date/time text. --detector nsdd uses only Apple NSDataDetector's matches; rules uses
     resolver.py's own patterns over the whole message; both (default) uses the rules and falls
     back to NSDataDetector's matches when the rules find no date.
  2. Pick the action with keyword rules: "remind" -> reminder; money or a spending verb ->
     expense; a future date, time or vague date -> event; otherwise none.
  3. Resolve values with resolver.resolve_action (the same conventions code the data validator
     uses); a convention that says ask -> clarify(field).
  4. Title/description = the message's own words minus date, time, amount and filler words, so B0
     can never invent a title word.
The result is validated by the same Pydantic schema as model output.

Usage:
  python harness/b0_calendar.py --out results/B0_calendar_dev [--detector both|rules|nsdd]
"""
import argparse
import re
import time

from calendar_schema import to_pred, validate_action
from io_utils import read_jsonl, write_jsonl
from resolver import VAGUE_DATE, local_ref, parse_amount, parse_date, parse_time, resolve_action

SPEND = re.compile(r"\b(spent|spend|paid|pay(?:ed)?|bought|cost|split|my share)\b", re.I)
REMIND = re.compile(r"\b(remind(?:er)?|don'?t forget)\b", re.I)
PAST_ONLY = re.compile(r"\b(yesterday|last night|last (?:week|mon|tue|wed|thu|fri|sat|sun)\w*)\b", re.I)
DECIMAL = re.compile(r"(?<![\d/:])\d+\.\d{2}\b")
FILLER = re.compile(
    r"\b(remind(?:er)?|me|to|pls|please|hey|hi|let'?s|want|grab|let me know|can we|could we|do|on|at|for|"
    r"around|after|from|by|was|is|my|i|spent|paid|bought|total|the|this|next|tonight|tonite|today|tomorrow|tmrw|"
    r"yesterday|last night|ish|long time no see|sorry|ok|okay|w)\b", re.I)


def detect(message, ref, detector):
    """-> (date_text, time_text, source). Text is what resolver.resolve_action will parse."""
    if detector in ("rules", "both"):
        if parse_date(message, ref.date()).value or parse_date(message, ref.date()).clarify or detector == "rules":
            return message, message, "rules"
    from nsdd import detect_dates
    hits = detect_dates(message)
    text = " ".join(h.text for h in hits)
    if detector == "nsdd":
        return text, text, "nsdd"
    # both: the rules found no date; take NSDataDetector's text for the date, rules for the time
    return (text or message), message, "nsdd" if text else "rules"


def choose_action(message, ref):
    if REMIND.search(message):
        return "reminder"
    if parse_amount(message).value or parse_amount(message).clarify or SPEND.search(message) or DECIMAL.search(message):
        return "expense"
    has_future = parse_date(message, ref.date()).value or parse_date(message, ref.date()).clarify \
        or parse_time(message, message).value or parse_time(message, message).clarify or VAGUE_DATE.search(message)
    if has_future and not (PAST_ONLY.search(message) and not parse_time(message, message).value):
        return "event"
    return "none"


def _strip(message, spans):
    text = message
    for s in spans:
        if s:
            text = text.replace(s, " ")
    # keep the sentence that still has content words (multi-sentence messages)
    text = FILLER.sub(" ", text)
    text = re.sub(r"[^\w'&/ -]+", " ", text)
    words = [w for w in text.split() if w not in ("-", "/")]
    return " ".join(words[:6]).strip()


def run_one(item, detector="both"):
    msg, tz = item["message"], item["tz"]
    ref = local_ref(item["reference_time"], tz)
    kind = choose_action(msg, ref)
    spans, source = {}, None
    if kind == "none":
        obj = {"action": "none"}
    else:
        if kind == "expense":
            spans = {"amount": msg, "date": msg}
        else:
            dtext, ttext, source = detect(msg, ref, detector)
            spans = {"date": dtext, "time": ttext, "duration": msg}
        r = resolve_action(kind, spans, msg, item["reference_time"], tz)
        if r.clarify:
            obj = {"action": "clarify", "fields": [r.clarify]}
        else:
            used = [parse_date(spans.get("date"), ref.date(), past=kind == "expense").matched,
                    parse_time(spans.get("time"), msg).matched,
                    parse_amount(msg, allow_bare=True).matched if kind == "expense" else None]
            words = _strip(msg, used) or kind
            if kind == "expense":
                obj = {"action": "expense", **r.value, "description": words}
            else:
                obj = {"action": kind, **r.value, "title": words}
    action, err = validate_action(obj)
    return action, err, {"detector_source": source, "chosen_kind": kind, "raw_output": obj}


def run(items, detector="both"):
    preds, traj = [], []
    for it in items:
        t0 = time.perf_counter()
        action, err, info = run_one(it, detector)
        preds.append(to_pred(it["id"], action))
        traj.append({"id": it["id"], "config": "B0", "detector": detector, **info, "schema_error": err,
                     "decision": "clarify" if preds[-1]["action"] == "clarify" else "act" if preds[-1]["action"] not in (None, "none") else str(preds[-1]["action"]),
                     "latency_ms": round((time.perf_counter() - t0) * 1000, 3)})
    return preds, traj


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--items", default="data/dev/calendar_dev.jsonl")
    ap.add_argument("--detector", choices=["both", "rules", "nsdd"], default="both")
    ap.add_argument("--out", required=True, help="output prefix, e.g. results/B0_calendar_dev")
    a = ap.parse_args()
    preds, traj = run(read_jsonl(a.items), a.detector)
    write_jsonl(a.out + "_pred.jsonl", preds)
    write_jsonl(a.out + "_trajectory.jsonl", traj)
    lat = sorted(t["latency_ms"] for t in traj)
    print(f"B0 ({a.detector}): {len(preds)} items, median {lat[len(lat) // 2]} ms, max {lat[-1]} ms (Mac)")
    print(f"Wrote {a.out}_pred.jsonl and {a.out}_trajectory.jsonl; score with eval/score_calendar.py")


if __name__ == "__main__":
    main()

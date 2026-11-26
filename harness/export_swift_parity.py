"""Export what the Python calendar code says on many inputs, so the Swift port (ios/CalendarCore)
can be checked against it: `cd ios/CalendarCore && swift run calcore-parity`.

Inputs: every dev item; every word n-gram (n <= 6) of every dev message plus hand-written edge
cases, through each resolver function; every model output saved in results/*_trajectory.jsonl;
and edge-case JSON for the schema. Dev data only; never data/test/.

  python harness/export_swift_parity.py   # writes ios/CalendarCore/Fixtures/parity.jsonl
"""
import json
import sys
from difflib import SequenceMatcher
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "harness"))
sys.path.insert(0, str(ROOT / "eval"))

from calendar_schema import parse_action, to_pred, validate_action  # noqa: E402
from resolver import (combine, local_ref, parse_amount, parse_date, parse_duration,  # noqa: E402
                      parse_time, resolve_action)
from run_calendar import local_now, user_message  # noqa: E402
from chat_prompt import render_llama32  # noqa: E402
from score_calendar import unsupported_words  # noqa: E402
from verify_calendar import check  # noqa: E402

OUT = ROOT / "ios" / "CalendarCore" / "Fixtures" / "parity.jsonl"

EXTRA = [  # edge cases beyond the dev messages
    "2-4pm", "10-2pm", "11 to 1pm", "9:30-10:15am", "7ish", "at 7", "@ 7", "19:00", "07:30", "0:30", "24:00",
    "12am", "12pm", "noon", "midnight", "midday lunch", "at 13pm", "7:75pm", "3 people", "$20 at 7pm", "11/20",
    "11/31", "2/29", "2/29/28", "13/1", "1/1/0000", "the 31st", "the 30th", "Feb 30", "30 Feb", "Sat at 5",
    "sat 5pm", "on sat", "Sun", "sun is out", "fri the 13th", "Friday the 6th", "Friday, the 7th", "next Mon",
    "last Fri", "this Wed", "tmrw", "2morrow 6pm", "day after tomorrow", "this evening at 8", "tonight 9",
    "sometime next week", "this weekend", "soon", "for 90 min", "for 1.5 hours", "2.5 min", "an hour and a half",
    "half an hour", "for two hours", "3 hrs", "$1,234.5", "€20", "£7.99", "₹500", "rs 500", "Rs. 1,200",
    "1.5k dollars", "20 bucks", "15 euros", "30 quid", "100 inr", "$20 and $30", "$20 or 20 dollars", "12",
    "12.50", "1/2", "7am", "7 am", "7a", "7 p.m.", "7p.m.", "at 7 and at 8", "from 5 to 6", "until 9pm",
    "breakfast at 8", "dinner at 8", "lunch at 1", "lunch at 11", "morning run 6", "Nov 1 2:30am",
    "Mar 14 2:30am", "Nov 1 1:30am", "dinner 11/26", "dentist Dec 31st 4pm", "Jan 1st 9am", "May 5",
    "may I come", "mar 3", "3rd of March", "the 2nd", "on the 15th", "١٢ pm", "dinner 🍕 Friday at 7",
    # convention fixes 2026-11-25
    "drinks fri or sat", "coffee wed or thurs", "sat/sun brunch", "sun and sand", "Friday next week",
    "a week from Friday", "in 3 days", "in two weeks", "in a week", "11-20", "11.20", "11-20-27", "9.30am",
    "1.5 hours", "lunch 11.20", "3 days ago", "two days ago", "tonight 7", "this evening 8", "meet 3 people tonight",
    "half past 6 dinner", "quarter past 9 breakfast", "quarter to 7 dinner", "half past 6", "quarter to 12 lunch",
    "C$20", "CA$20", "A$15", "c$5 coffee", "remind me tomorrow evening to call mom", "remind me tonight",
    "coffee 4.75", "11.20.26", "4-75", "2-30", "lunch 11.20 yesterday",
]

BAD_JSON = [
    '{"action": "event", "title": "x", "start": "2026-11-06T19:00:00-05:00", "duration_min": "60"}',
    '{"action": "event", "title": "x", "start": "2026-11-06T19:00:00-05:00", "duration_min": " 6_0 "}',
    '{"action": "event", "title": "x", "start": "2026-11-06T19:00:00-05:00", "duration_min": 60.0}',
    '{"action": "event", "title": "x", "start": "2026-11-06T19:00:00-05:00", "duration_min": 60.5}',
    '{"action": "event", "title": "x", "start": "2026-11-06T19:00:00-05:00", "duration_min": true}',
    '{"action": "event", "title": "x", "start": "2026-11-06T19:00:00-05:00", "duration_min": 0}',
    '{"action": "event", "title": "x", "start": "2026-11-06T19:00:00-05:00", "duration_min": 1441}',
    '{"action": "event", "title": "x", "start": "2026-11-06T19:00:00Z", "duration_min": 60}',
    '{"action": "event", "title": "x", "start": "2026-11-06 19:00-05:00", "duration_min": 60}',
    '{"action": "event", "title": "x", "start": "2026-11-06T19:00:00+0500", "duration_min": 60}',
    '{"action": "event", "title": "x", "start": "2026-11-06T19:00:00+05", "duration_min": 60}',
    '{"action": "event", "title": "x", "start": "2026-11-06T19:00:00.25-05:00", "duration_min": 60}',
    '{"action": "event", "title": "x", "start": "2026-11-06T19:00:00", "duration_min": 60}',
    '{"action": "event", "title": "x", "start": 1700000000, "duration_min": 60}',
    '{"action": "event", "title": "x", "start": "1700000000", "duration_min": 60}',
    '{"action": "event", "title": "x", "start": "2026-11-31T19:00:00-05:00", "duration_min": 60}',
    '{"action": "event", "title": "  ", "start": "2026-11-06T19:00:00-05:00", "duration_min": 60}',
    '{"action": "event", "title": 5, "start": "2026-11-06T19:00:00-05:00", "duration_min": 60}',
    '{"action": "event", "title": "x", "start": "2026-11-06T19:00:00-05:00", "duration_min": 60, "spans": null}',
    '{"action": "event", "title": "x", "start": "2026-11-06T19:00:00-05:00", "duration_min": 60, "spans": {"x": "a"}}',
    '{"action": "event", "title": "x", "start": "2026-11-06T19:00:00-05:00", "duration_min": 60, "spans": {"date": 5}}',
    '{"action": "event", "title": "x", "start": "2026-11-06T19:00:00-05:00", "duration_min": 60, "foo": 1}',
    '{"action": "event", "title": "a", "title": "b", "start": "2026-11-06T19:00:00-05:00", "duration_min": 60}',
    '{"action": "reminder", "title": "x", "start": "2026-11-06T09:00:00-05:00"}',
    '{"action": "expense", "amount": "23.500", "currency": "USD", "description": "x", "date": "2026-11-01"}',
    '{"action": "expense", "amount": 23.5, "currency": "USD", "description": "x", "date": "2026-11-01"}',
    '{"action": "expense", "amount": 23, "currency": "USD", "description": "x", "date": "2026-11-01"}',
    '{"action": "expense", "amount": "1e2", "currency": "USD", "description": "x", "date": "2026-11-01"}',
    '{"action": "expense", "amount": "1.234e1", "currency": "USD", "description": "x", "date": "2026-11-01"}',
    '{"action": "expense", "amount": "100e-2", "currency": "USD", "description": "x", "date": "2026-11-01"}',
    '{"action": "expense", "amount": "0.001", "currency": "USD", "description": "x", "date": "2026-11-01"}',
    '{"action": "expense", "amount": 1e-05, "currency": "USD", "description": "x", "date": "2026-11-01"}',
    '{"action": "expense", "amount": ".5", "currency": "USD", "description": "x", "date": "2026-11-01"}',
    '{"action": "expense", "amount": "5.", "currency": "USD", "description": "x", "date": "2026-11-01"}',
    '{"action": "expense", "amount": "+5", "currency": "USD", "description": "x", "date": "2026-11-01"}',
    '{"action": "expense", "amount": "-5", "currency": "USD", "description": "x", "date": "2026-11-01"}',
    '{"action": "expense", "amount": "1,000", "currency": "USD", "description": "x", "date": "2026-11-01"}',
    '{"action": "expense", "amount": "1_000", "currency": "USD", "description": "x", "date": "2026-11-01"}',
    '{"action": "expense", "amount": "999999.99", "currency": "USD", "description": "x", "date": "2026-11-01"}',
    '{"action": "expense", "amount": "1000000", "currency": "USD", "description": "x", "date": "2026-11-01"}',
    '{"action": "expense", "amount": "0", "currency": "USD", "description": "x", "date": "2026-11-01"}',
    '{"action": "expense", "amount": "NaN", "currency": "USD", "description": "x", "date": "2026-11-01"}',
    '{"action": "expense", "amount": true, "currency": "USD", "description": "x", "date": "2026-11-01"}',
    '{"action": "expense", "amount": "5", "currency": " USD ", "description": "x", "date": "2026-11-01"}',
    '{"action": "expense", "amount": "5", "currency": "usd", "description": "x", "date": "2026-11-01"}',
    '{"action": "expense", "amount": "5", "currency": "USD", "description": "x", "date": "2026-11-01T00:00:00"}',
    '{"action": "expense", "amount": "5", "currency": "USD", "description": "x", "date": "2026-11-1"}',
    '{"action": "expense", "amount": "5", "currency": "USD", "description": "x", "date": 1700000000}',
    '{"action": "expense", "amount": "5", "currency": "USD", "description": "x", "date": "2026-11-01", "spans": {"amount": " $5 "}}',
    '{"action": "none"}', '{"action": "none", "spans": {}}', '{"action": "Event"}', '{"title": "x"}',
    '{"action": "clarify", "fields": ["date", "date"]}', '{"action": "clarify", "fields": ["date", "ampm", "amount", "conflict"]}',
    '{"action": "clarify", "fields": ["date", "date", "ampm", "amount"]}', '{"action": "clarify", "fields": "date"}',
    '{"action": "clarify", "fields": []}', '{"action": "clarify", "fields": ["time"]}', '{"action": "clarify", "fields": [1]}',
    '```json\n{"action": "none"}\n```', 'Sure! {"action": "none"} Hope that helps.', '{"action": "none"', 'no json here',
    '{"action": "none"} {"action": "clarify"}', '{"action": "none", "x": NaN}', '[{"action": "none"}]',
    '{"action": "event", "title": "caf\\u00e9 \\ud83c\\udf55", "start": "2026-11-06T19:00:00-05:00", "duration_min": 60}',
]


def p_out(p, conv=lambda v: v):
    return {"value": None if p.value is None else conv(p.value), "clarify": p.clarify, "matched": p.matched}


def safe(fn):
    try:
        return fn()
    except Exception as e:  # noqa: BLE001  (recorded; the Swift side skips these)
        return {"error": f"{type(e).__name__}: {e}"}


def ngrams(message, n=6):
    w = message.split()
    out = {message}
    for i in range(len(w)):
        for j in range(i + 1, min(len(w), i + n) + 1):
            out.add(" ".join(w[i:j]))
    return sorted(out)


def main():
    items =[json.loads(line) for line in open(ROOT / "data/dev/calendar_dev.jsonl") if line.strip()]
    rows = []
    ctx = lambda it: {"id": it["id"], "message": it["message"], "reference_time": it["reference_time"], "tz": it["tz"]}

    system = (ROOT / "prompts/calendar_v0.txt").read_text()
    for it in items:
        rows.append({"t": "user_message", "item": ctx(it), "out": user_message(it)})
        # The prompt the Mac runner feeds the model (chat_prompt.render_llama32, reference date).
        rows.append({"t": "chat_prompt", "item": ctx(it), "out": render_llama32(system, user_message(it), local_now(it))})
        g = it["gold"]
        kind = g["action"] if g["action"] in ("event", "reminder", "expense") else g.get("intended")
        if kind:
            spans = {k: v for k, v in (g.get("spans") or {}).items() if v is not None}
            r = safe(lambda: p_out(resolve_action(kind, spans, it["message"], it["reference_time"], it["tz"])))
            rows.append({"t": "resolve", "kind": kind, "spans": spans, "item": ctx(it), "out": r})

    texts = [(it["message"], it["reference_time"], it["tz"]) for it in items]
    texts += [(m, "2026-11-02T10:00:00-05:00", "America/New_York") for m in EXTRA]
    texts += [(m, "2027-03-12T10:00:00-05:00", "America/New_York") for m in EXTRA[:20]]
    seen = set()
    for msg, ref, tz in texts:
        day = local_ref(ref, tz).date()
        for t in ngrams(msg):
            for past in (False, True):
                if ("d", t, day, past) not in seen:
                    seen.add(("d", t, day, past))
                    rows.append({"t": "date", "text": t, "ref": day.isoformat(), "past": past,
                                 "out": safe(lambda: p_out(parse_date(t, day, past), lambda d: d.isoformat()))})
            rows.append({"t": "time", "text": t, "message": msg,
                         "out": safe(lambda: p_out(parse_time(t, msg),
                                                   lambda v: {"start": v.start.strftime("%H:%M"), "dur": v.duration_min}))})
            if ("u", t) not in seen:
                seen.add(("u", t))
                rows.append({"t": "duration", "text": t, "out": safe(lambda: p_out(parse_duration(t)))})
                for bare in (False, True):
                    rows.append({"t": "amount", "text": t, "allow_bare": bare,
                                 "out": safe(lambda: p_out(parse_amount(t, allow_bare=bare),
                                                           lambda v: [f"{v[0]:.2f}", v[1]]))})
            for title in {t, t + " meeting", "dinnr " + t, t.upper()}:
                rows.append({"t": "title", "title": title, "message": msg, "out": unsupported_words(title, msg)})

    for d in ("2026-03-08", "2026-11-01", "2027-03-14", "2027-11-07", "2026-06-15"):
        for hm in ("01:30", "02:00", "02:30", "03:00", "00:00", "23:59"):
            for tz in ("America/New_York", "Europe/London", "Asia/Kolkata", "Australia/Lord_Howe", "America/Los_Angeles"):
                from datetime import date, time
                c = combine(date.fromisoformat(d), time.fromisoformat(hm), tz)
                rows.append({"t": "combine", "day": d, "hm": hm, "tz": tz,
                             "out": {"value": c.value.isoformat(timespec="seconds") if c.value else None, "clarify": c.clarify}})

    for a, b in [("dinnr", "dinner"), ("meeting", "meting"), ("abc", "xyz"), ("standup", "stand"), ("", ""),
                 ("aaaa", "aaa"), ("ababab", "bababa"), ("dentist", "dentists")]:
        rows.append({"t": "ratio", "a": a, "b": b, "out": SequenceMatcher(None, a, b).ratio()})

    by_id = {it["id"]: it for it in items}
    raws = []
    for f in sorted((ROOT / "results").glob("*calendar*_trajectory.jsonl")) + [ROOT / "results/try_trajectory.jsonl"]:
        if not f.exists():
            continue
        for line in open(f):
            t = json.loads(line)
            if isinstance(t.get("raw_output"), str) and t["id"] in by_id:
                raws.append((t["id"], t["raw_output"]))
            rep = t.get("repair") or {}
            if isinstance(rep, dict) and isinstance(rep.get("raw_output"), str) and t["id"] in by_id:
                raws.append((t["id"], rep["raw_output"]))
    raws += [("cal-001", b) for b in BAD_JSON]
    seen_raw = set()
    for iid, raw in raws:
        if (iid, raw) in seen_raw:
            continue
        seen_raw.add((iid, raw))
        action, err = parse_action(raw)
        rows.append({"t": "parse", "raw": raw, "out": to_pred(iid, action), "valid": action is not None})
        if action is not None:
            for policy in ("drop_and_merge", "strict"):
                for cross in (True, False):
                    v = check(by_id[iid], action, "nsdatadetector" if cross else None, policy)
                    rows.append({"t": "check", "item": ctx(by_id[iid]), "raw": raw, "policy": policy, "crosscheck": cross,
                                 "out": {"ok": v["ok"], "failed": v["failed"], "clarify_field": v["clarify_field"]}})

    OUT.parent.mkdir(parents=True, exist_ok=True)
    with open(OUT, "w") as f:
        for r in rows:
            f.write(json.dumps(r) + "\n")
    counts = {}
    for r in rows:
        counts[r["t"]] = counts.get(r["t"], 0) + 1
    print(f"wrote {len(rows)} rows to {OUT.relative_to(ROOT)}: {counts}")
    _ = validate_action  # imported for symmetry with the Swift API


if __name__ == "__main__":
    main()

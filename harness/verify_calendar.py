"""C3: code-based verification of a schema-valid action. Detects semantically wrong values.

Checks (each recorded in the verdict, so its value can be measured on its own):
  span_verbatim   every span the model returned appears verbatim in the message
  spans_present   an event has date and time spans, a reminder a date span, an expense an amount span
  resolve         re-resolving the spans with the conventions (resolver.py) gives the same start and
                  duration (events/reminders) or the same amount, currency and date (expenses);
                  if the conventions say ask, the verifier asks
  title           no title/description word is missing from the message (conventions.md)
  nsdd            (optional, verifier.calendar_crosscheck: nsdatadetector) Apple NSDataDetector
                  finds date text overlapping the date span

Recovery when a check fails (verifier.recovery):
  clarify   (C3 as proposed) return clarify(field), naming the field that failed
  b0        deterministic fallback: return B0's action for the message
  repair    handled in run_calendar.py: ONE capped retry with the failure as feedback, then clarify
`none` and `clarify` outputs pass through unchanged: the verifier checks values, and they have none.
"""
import sys
from pathlib import Path

from calendar_schema import Clarify, Event, Expense, Reminder
from resolver import parse_amount, resolve_action

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "eval"))
from score_calendar import same_time, unsupported_words  # noqa: E402  (the conventions' title rule)

FIELD_FOR = {"date": "date", "time": "start_time", "duration": "start_time", "amount": "amount",
             "title": "conflict", "description": "conflict", "nsdd": "date"}


def _spans(action):
    return action.spans.model_dump() if hasattr(action, "spans") else {}


def check(item, action, crosscheck=None):
    """-> verdict dict: {"ok", "failed": [check names], "clarify_field", "details"}."""
    msg = item["message"]
    if not isinstance(action, (Event, Reminder, Expense)):
        return {"ok": True, "failed": [], "clarify_field": None, "details": {}}
    spans, failed, details, field = _spans(action), [], {}, None

    def fail(name, fld, why):
        nonlocal field
        failed.append(name)
        details[name] = why
        field = field or fld

    for k, s in spans.items():
        if s is not None and s.lower() not in msg.lower():
            fail("span_verbatim", FIELD_FOR.get(k, "conflict"), f"{k}={s!r}")
    need = {"event": ["date", "time"], "reminder": ["date"], "expense": ["amount"]}[action.action]
    for k in need:
        if not spans.get(k):
            fail("spans_present", FIELD_FOR[k], f"no {k} span")

    kind = action.action
    r = resolve_action(kind, spans, msg, item["reference_time"], item["tz"])
    if r.clarify:
        fail("resolve", r.clarify, f"conventions say clarify({r.clarify})")
    elif kind == "expense":
        amt = parse_amount(spans.get("amount"), allow_bare=True).value
        if r.value["amount"] != f"{action.amount:.2f}" or r.value["currency"] != action.currency:
            fail("resolve", "amount", f"text says {amt}, model says {action.amount} {action.currency}")
        if r.value["date"] != action.date.isoformat():
            fail("resolve", "date", f"text says {r.value['date']}, model says {action.date}")
    else:
        if not same_time(r.value["start"], action.start.isoformat()):
            fail("resolve", "start_time", f"text says {r.value['start']}, model says {action.start.isoformat()}")
        if kind == "event" and r.value["duration_min"] != action.duration_min:
            fail("resolve", "start_time", f"text says {r.value['duration_min']} min, model says {action.duration_min}")

    words = unsupported_words(action.description if kind == "expense" else action.title, msg)
    if words:
        fail("title", "conflict", f"not in message: {words}")

    if crosscheck == "nsdatadetector" and kind in ("event", "reminder") and spans.get("date"):
        import nsdd
        if nsdd.available():
            low = msg.lower()
            pos = low.find(spans["date"].lower())
            hits = nsdd.detect_dates(msg)
            if pos >= 0 and not any(h.start < pos + len(spans["date"]) and pos < h.end for h in hits):
                fail("nsdd", "date", "NSDataDetector finds no date at the date span")
    return {"ok": not failed, "failed": failed, "clarify_field": field, "details": details}


def make_verifier(cfg):
    """-> fn(item, action) -> (final action, verdict). Used by run_calendar.py."""
    vcfg = cfg.get("verifier") or {}
    crosscheck = vcfg.get("calendar_crosscheck")
    recovery = vcfg.get("recovery", "clarify")

    def verify(item, action):
        verdict = check(item, action, crosscheck)
        verdict["recovery"] = None
        if verdict["ok"]:
            return action, verdict
        if recovery == "repair" and not verdict.get("is_retry"):
            verdict["recovery"] = "repair_pending"  # run_calendar.py makes the single retry
            return action, verdict
        if recovery == "b0":
            from b0_calendar import run_one
            b0_action, _, _ = run_one(item)
            verdict["recovery"] = "b0"
            return b0_action, verdict
        # clarify (and the final step of repair, once its single retry is spent)
        verdict["recovery"] = "clarify"
        return Clarify(action="clarify", fields=[verdict["clarify_field"]]), verdict

    verify.recovery = recovery
    return verify

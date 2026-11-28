"""C3: code-based verification of a schema-valid action. Detects semantically wrong values.

Checks (each recorded in the verdict, so its value can be measured on its own):
  span_verbatim   (span_policy: strict, v1) every span appears verbatim in the message, and an event
                  has date and time spans; with drop_and_merge (v2, default) spans not in the message
                  are ignored and date/time are read from both spans together (see CHANGELOG)
  resolve         re-resolving the spans with the conventions (resolver.py) gives the same start and
                  duration (events/reminders) or the same amount, currency and date (expenses);
                  if the conventions say ask, the verifier asks
  title           no title/description word is missing from the message (conventions.md)
  nsdd            (optional, verifier.calendar_crosscheck: nsdatadetector) Apple NSDataDetector
                  finds date text overlapping the date span

Value source (verifier.value_source):
  model     (C3 as proposed) the model's date, time, duration and amount are checked against the
            values the conventions give for its spans; a mismatch triggers recovery
  code      (C3 + code values) the model only chooses the action, the title and the source spans;
            the values are computed from those spans by the conventions code (resolver.py), so the
            model's own date arithmetic is never used. The title check and the NSDataDetector check
            still apply. See recompute().

Recovery when a check fails (verifier.recovery):
  clarify   (C3 as proposed) return clarify(field), naming the field that failed
  b0        deterministic fallback: return B0's action for the message
  repair    handled in run_calendar.py: ONE capped retry with the failure as feedback, then clarify
`none` and `clarify` outputs pass through unchanged: the verifier checks values, and they have none.
"""
import sys
from pathlib import Path

from calendar_schema import Clarify, Event, Expense, Reminder
from resolver import mentions_date, parse_amount, resolve_action

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "eval"))
from score_calendar import same_time, unsupported_words  # noqa: E402  (the conventions' title rule)

FIELD_FOR = {"date": "date", "time": "start_time", "duration": "start_time", "amount": "amount",
             "title": "conflict", "description": "conflict", "nsdd": "date"}


def _spans(action):
    return action.spans.model_dump() if hasattr(action, "spans") else {}


def check(item, action, crosscheck=None, span_policy="drop_and_merge"):
    """-> verdict dict: {"ok", "failed": [check names], "clarify_field", "details"}."""
    msg = item["message"]
    if not isinstance(action, (Event, Reminder, Expense)):
        return {"ok": True, "failed": [], "clarify_field": None, "details": {}}
    spans, failed, details, field = _spans(action), [], {}, None
    orig_date = spans.get("date")

    def fail(name, fld, why):
        nonlocal field
        failed.append(name)
        details[name] = why
        field = field or fld

    kind = action.action
    not_verbatim = {k: s for k, s in spans.items() if s is not None and s.lower() not in msg.lower()}
    if span_policy == "strict":
        # v1: any span not copied from the message fails.
        for k, s in not_verbatim.items():
            fail("span_verbatim", FIELD_FOR.get(k, "conflict"), f"{k}={s!r}")
        used = spans
    else:
        # v2 (drop_and_merge): a span not in the message is ignored, so the conventions' defaults
        # apply; date and time are read from the date and time spans together, so a span filed
        # under the wrong key does not matter. The value must still match exactly.
        if not_verbatim:
            details["dropped_spans"] = not_verbatim
        used = {k: (None if k in not_verbatim else s) for k, s in spans.items()}
        if kind in ("event", "reminder"):
            joined = " ".join(s for s in (used.get("date"), used.get("time")) if s) or None
            used = {**used, "date": joined, "time": joined}
    need = {"event": ["date", "time"], "reminder": ["date"], "expense": ["amount"]}[kind]
    for k in need:
        if span_policy == "strict" and not used.get(k):
            fail("spans_present", FIELD_FOR[k], f"no {k} span")

    r = resolve_action(kind, used, msg, item["reference_time"], item["tz"])
    spans = used
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

    if crosscheck == "nsdatadetector" and kind in ("event", "reminder") and orig_date \
            and orig_date.lower() in msg.lower():
        import nsdd
        if nsdd.available():
            low = msg.lower()
            pos = low.find(orig_date.lower())
            hits = nsdd.detect_dates(msg)
            if pos >= 0 and not any(h.start < pos + len(orig_date) and pos < h.end for h in hits):
                fail("nsdd", "date", "NSDataDetector finds no date at the date span")
    return {"ok": not failed, "failed": failed, "clarify_field": field, "details": details}


def _spans_used(action, msg):
    """drop_and_merge: spans not in the message are ignored; date and time are read together."""
    spans = _spans(action)
    used = {k: (s if s is not None and s.lower() in msg.lower() else None) for k, s in spans.items()}
    if action.action in ("event", "reminder"):
        joined = " ".join(s for s in (used.get("date"), used.get("time")) if s) or None
        used = {**used, "date": joined, "time": joined}
        if not mentions_date(joined):
            # The model's date words are not in the message (it copied the prompt's "Now:" line,
            # say), so its kept words name no date: read the date and time from the whole message.
            used = {**used, "date": msg, "time": msg}
    return used


def recompute(item, action, crosscheck=None):
    """C3 + code values: keep the model's action, title and spans; compute every value from the spans.
    -> (final action, verdict). The verdict lists the fields where code replaced the model's value."""
    from datetime import date as _date, datetime
    from decimal import Decimal

    msg = item["message"]
    if not isinstance(action, (Event, Reminder, Expense)):
        return action, {"ok": True, "failed": [], "clarify_field": None, "details": {}, "replaced": []}
    kind = action.action
    r = resolve_action(kind, _spans_used(action, msg), msg, item["reference_time"], item["tz"])
    verdict = {"ok": True, "failed": [], "clarify_field": None, "details": {}, "replaced": []}

    def ask(name, fld, why):
        verdict.update(ok=False, clarify_field=verdict["clarify_field"] or fld)
        verdict["failed"].append(name)
        verdict["details"][name] = why

    title = action.description if kind == "expense" else action.title
    words = unsupported_words(title, msg)
    if words:
        ask("title", "conflict", f"not in message: {words}")
    if r.clarify:
        ask("resolve", r.clarify, f"conventions say clarify({r.clarify})")
    if crosscheck == "nsdatadetector" and kind in ("event", "reminder"):
        nd = check(item, action, crosscheck, "drop_and_merge")
        if "nsdd" in nd["failed"]:
            ask("nsdd", "date", nd["details"]["nsdd"])
    if not verdict["ok"]:
        return Clarify(action="clarify", fields=[verdict["clarify_field"]]), verdict

    v = r.value
    if kind == "expense":
        new = Expense(action="expense", amount=Decimal(v["amount"]), currency=v["currency"],
                      description=action.description, date=_date.fromisoformat(v["date"]), spans=action.spans)
        if v["amount"] != f"{action.amount:.2f}" or v["currency"] != action.currency:
            verdict["replaced"].append("amount")
        if v["date"] != action.date.isoformat():
            verdict["replaced"].append("date")
    else:
        start = datetime.fromisoformat(v["start"])
        if not same_time(v["start"], action.start.isoformat()):
            verdict["replaced"].append("start")
        if kind == "event":
            new = Event(action="event", title=action.title, start=start, duration_min=v["duration_min"], spans=action.spans)
            if v["duration_min"] != action.duration_min:
                verdict["replaced"].append("duration")
        else:
            new = Reminder(action="reminder", title=action.title, start=start, spans=action.spans)
    return new, verdict


def make_verifier(cfg):
    """-> fn(item, action) -> (final action, verdict). Used by run_calendar.py."""
    vcfg = cfg.get("verifier") or {}
    crosscheck = vcfg.get("calendar_crosscheck")
    recovery = vcfg.get("recovery", "clarify")
    span_policy = vcfg.get("span_policy", "drop_and_merge")
    value_source = vcfg.get("value_source", "model")

    def verify(item, action):
        if value_source == "code":
            final, verdict = recompute(item, action, crosscheck)
            verdict["recovery"] = None if verdict["ok"] else "clarify"
            return final, verdict
        verdict = check(item, action, crosscheck, span_policy)
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

    verify.recovery = recovery if value_source == "model" else "clarify"
    verify.span_policy = span_policy
    verify.value_source = value_source
    return verify

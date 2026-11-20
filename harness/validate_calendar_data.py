"""Check the calendar dev pilot: recompute every gold value from the conventions and fail on any mismatch.

Usage: python harness/validate_calendar_data.py [--items data/dev/calendar_dev.jsonl] [--mode strict|review]

--mode strict (default, our dev pilot): any disagreement with the conventions code fails.
--mode review (data written by someone who has not seen resolver.py, e.g. blind dev items or the
test set): disagreements are listed for a person to check against conventions.md and do not fail,
so the data is never bent toward what our code can parse. Structural errors (ids, offsets, spans
not in the message, bad fields) still fail in both modes.

Gold values were typed by hand. This script re-derives each one with resolver.py (zoneinfo for
offsets and DST) from the item's annotated source spans, so a mismatch means either the label or
the resolver is wrong, and someone must look. It also checks:
  - ids are unique; reference_time carries the right offset for its time zone at that instant;
  - every annotated span appears verbatim in the message, and so does every title/description term;
  - clarify items use allowed fields, and re-resolving their spans asks for one of those fields;
  - the slice mix: every clarify field, DST, month/year ends, messy inputs, expenses and none.
"""
import argparse
import json
import sys
from collections import Counter
from datetime import datetime
from zoneinfo import ZoneInfo

from calendar_schema import CLARIFY_FIELDS
from resolver import resolve_action

ACTIONS = {"event", "reminder", "expense", "none", "clarify"}
MIN_SLICES = {"dst": 4, "month_end": 6, "messy": 8, "expense": 12, "none": 5, "clarify": 10}


def load(path):
    with open(path) as f:
        return [json.loads(line) for line in f if line.strip()]


def _check_spans(it, spans, errors):
    for name, span in (spans or {}).items():
        if span is not None and span not in it["message"]:
            errors.append(f"{it['id']}: span {name}={span!r} is not verbatim in the message")


def validate_item(it):
    errors = []
    iid, g, msg = it.get("id", "?"), it.get("gold", {}), it.get("message", "")
    for key in ("id", "message", "reference_time", "tz", "slice", "gold"):
        if key not in it:
            errors.append(f"{iid}: missing {key}")
    if errors:
        return errors
    ref = datetime.fromisoformat(it["reference_time"])
    if ref.utcoffset() != ref.astimezone(ZoneInfo(it["tz"])).utcoffset():
        errors.append(f"{iid}: reference_time offset is wrong for {it['tz']}")
    action = g.get("action")
    if action not in ACTIONS:
        return errors + [f"{iid}: unknown action {action!r}"]
    if action == "none":
        return errors
    _check_spans(it, g.get("spans"), errors)

    if action == "clarify":
        bad = set(g.get("fields", [])) - set(CLARIFY_FIELDS)
        if not g.get("fields") or bad:
            errors.append(f"{iid}: clarify fields must be non-empty and allowed (bad: {sorted(bad)})")
        if g.get("intended") not in ("event", "reminder", "expense"):
            errors.append(f"{iid}: clarify item needs intended event|reminder|expense")
            return errors
        r = resolve_action(g["intended"], g.get("spans"), msg, it["reference_time"], it["tz"])
        if r.clarify not in g.get("fields", []):
            errors.append(f"{iid}: RESOLVE conventions resolve to {r.clarify or r.value!r}, gold asks {g.get('fields')}")
        return errors

    terms = g.get("description_terms" if action == "expense" else "title_terms") or []
    if not terms:
        errors.append(f"{iid}: needs at least one key term")
    for t in terms:
        if t.lower() not in msg.lower():
            errors.append(f"{iid}: key term {t!r} not in message")
    r = resolve_action(action, g.get("spans"), msg, it["reference_time"], it["tz"])
    if r.clarify:
        errors.append(f"{iid}: RESOLVE conventions say clarify({r.clarify}), gold is {action}")
        return errors
    want = {k: g.get(k) for k in r.value}
    if action == "event" and g.get("duration_min") is None:
        want["duration_min"] = 60
    for k, v in r.value.items():
        if want[k] != v:
            errors.append(f"{iid}: RESOLVE {k} gold {want[k]!r} != conventions {v!r}")
    return errors


def validate(items):
    errors = []
    for iid, c in Counter(it.get("id") for it in items).items():
        if c > 1:
            errors.append(f"{iid}: duplicate item id")
    for it in items:
        errors += validate_item(it)
    return errors


def coverage(items):
    """Slice-mix problems (a dev pilot that misses a case can't tune for it)."""
    problems = []
    slices = Counter(s for it in items for s in it["slice"])
    for s, n in MIN_SLICES.items():
        if slices[s] < n:
            problems.append(f"slice {s}: {slices[s]} items, want >= {n}")
    asked = {f for it in items if it["gold"]["action"] == "clarify" for f in it["gold"]["fields"]}
    for f in CLARIFY_FIELDS:
        if f not in asked:
            problems.append(f"no clarify item for field {f}")
    return problems


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--items", default="data/dev/calendar_dev.jsonl")
    ap.add_argument("--mode", choices=["strict", "review"], default="strict")
    ap.add_argument("--no-coverage", action="store_true", help="skip slice-mix checks (small extra sets)")
    a = ap.parse_args()
    items = load(a.items)
    errors = validate(items) + ([] if a.no_coverage else coverage(items))
    if a.mode == "review":
        review = [e for e in errors if "RESOLVE" in e]
        errors = [e for e in errors if "RESOLVE" not in e]
        for e in review:
            print("NEEDS HUMAN CHECK", e)
        print(f"{len(review)} items for a person to check against conventions.md")
    print(f"{len(items)} items")
    print("actions:", dict(Counter(it["gold"]["action"] for it in items)))
    print("slices:", dict(Counter(s for it in items for s in it["slice"])))
    for e in errors:
        print("ERROR", e)
    print("OK" if not errors else f"{len(errors)} errors")
    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()

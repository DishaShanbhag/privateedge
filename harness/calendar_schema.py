"""The calendar/actions output schema (Pydantic). All validation happens here, in code.

The model (or B0) returns exactly one action as a JSON object:

  {"action": "event", "title": "Dinner", "start": "2026-11-06T19:00:00-05:00", "duration_min": 60,
   "spans": {"date": "Friday", "time": "at 7", "duration": null, "title": "dinner"}}
  {"action": "reminder", "title": "Pay rent", "start": "2026-11-06T09:00:00-05:00",
   "spans": {"date": "Friday", "time": null, "title": "pay rent"}}
  {"action": "expense", "amount": "23.50", "currency": "USD", "description": "lunch", "date": "2026-11-01",
   "spans": {"amount": "$23.50", "date": "yesterday", "description": "lunch"}}
  {"action": "none"}
  {"action": "clarify", "fields": ["ampm"]}

`spans` are words copied from the message that each value came from (null if the message has
none). C0-C2 only log them; C3 checks them (verify_calendar.py).

    action, error = parse_action(raw_text)   # action is None when the output is not schema-valid
    pred = to_pred(item_id, action)          # the predictions-file row the scorer reads
"""
import json
import re
from datetime import date
from decimal import Decimal
from typing import Annotated, Literal, Optional, Union

from pydantic import AwareDatetime, BaseModel, ConfigDict, Field, TypeAdapter, ValidationError, field_validator

CLARIFY_FIELDS = ("date", "start_time", "ampm", "which_event", "conflict", "invalid_time", "amount")
ClarifyField = Literal["date", "start_time", "ampm", "which_event", "conflict", "invalid_time", "amount"]
Span = Optional[Annotated[str, Field(max_length=120)]]
Text = Annotated[str, Field(min_length=1, max_length=120)]


class _Strict(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)


class EventSpans(_Strict):
    date: Span = None
    time: Span = None
    duration: Span = None
    title: Span = None


class ReminderSpans(_Strict):
    date: Span = None
    time: Span = None
    title: Span = None


class ExpenseSpans(_Strict):
    amount: Span = None
    date: Span = None
    description: Span = None


class Event(_Strict):
    action: Literal["event"]
    title: Text
    start: AwareDatetime
    duration_min: int = Field(gt=0, le=24 * 60)
    spans: EventSpans = EventSpans()


class Reminder(_Strict):
    action: Literal["reminder"]
    title: Text
    start: AwareDatetime
    spans: ReminderSpans = ReminderSpans()


class Expense(_Strict):
    action: Literal["expense"]
    amount: Decimal = Field(gt=0, lt=Decimal("1000000"), decimal_places=2)
    currency: str = Field(pattern=r"^[A-Z]{3}$")
    description: Text
    date: date
    spans: ExpenseSpans = ExpenseSpans()

    @field_validator("amount", mode="before")
    @classmethod
    def _no_float_noise(cls, v):
        # 23.5 (JSON number) -> "23.5" before Decimal, so binary floats never leak in.
        return str(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else v


class NoAction(_Strict):
    action: Literal["none"]


class Clarify(_Strict):
    action: Literal["clarify"]
    fields: list[ClarifyField] = Field(min_length=1, max_length=3)

    @field_validator("fields", mode="before")
    @classmethod
    def _dedupe(cls, v):
        # A grammar cannot forbid repeats, and ["date", "date"] still names the field, so repeats
        # are dropped (first occurrence kept) rather than failing the whole output.
        return list(dict.fromkeys(v)) if isinstance(v, list) else v


Action = Annotated[Union[Event, Reminder, Expense, NoAction, Clarify], Field(discriminator="action")]
_ADAPTER = TypeAdapter(Action)


def extract_json(text):
    """The first {...} block in the text (code fences allowed), or None."""
    s = re.sub(r"^```(?:json)?\s*|\s*```$", "", text.strip())
    start, end = s.find("{"), s.rfind("}")
    if start == -1 or end < start:
        return None
    try:
        obj = json.loads(s[start:end + 1])
    except json.JSONDecodeError:
        return None
    return obj if isinstance(obj, dict) else None


def validate_action(obj):
    """dict -> (Action, None) or (None, short error)."""
    try:
        return _ADAPTER.validate_python(obj), None
    except ValidationError as e:
        err = e.errors()[0]
        return None, f"schema: {'.'.join(str(p) for p in err['loc'])}: {err['msg']}"


def parse_action(text):
    """Raw model text -> (Action, None) or (None, error). Never raises."""
    obj = extract_json(text)
    if obj is None:
        return None, "not_json"
    return validate_action(obj)


def to_pred(item_id, action):
    """The predictions-file row for one item. A schema-invalid output scores as wrong."""
    if action is None:
        return {"id": item_id, "action": None, "schema_valid": False}
    row = {"id": item_id, "action": action.action, "schema_valid": True}
    if isinstance(action, (Event, Reminder)):
        row.update(start=action.start.isoformat(), title=action.title)
        if isinstance(action, Event):
            row["duration_min"] = action.duration_min
    elif isinstance(action, Expense):
        row.update(amount=f"{action.amount:.2f}", currency=action.currency,
                   description=action.description, date=action.date.isoformat())
    elif isinstance(action, Clarify):
        row["fields"] = list(action.fields)
    return row


def action_json_schema():
    return _ADAPTER.json_schema()

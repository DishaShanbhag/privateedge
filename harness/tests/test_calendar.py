"""Calendar/actions: schema, resolver, parser. Expected values come from conventions.md and the
worked examples in docs/milestone2.pdf (Section 6), not from the resolver itself."""
import sys
from datetime import date, time
from decimal import Decimal
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from calendar_schema import Clarify, Event, Expense, parse_action, to_pred  # noqa: E402
from resolver import combine, iso, parse_amount, parse_date, parse_duration, parse_time  # noqa: E402

NY = "America/New_York"
MON = date(2026, 11, 2)       # default reference date
NYE = date(2026, 12, 31)      # Thu, year end
PRE_DST = date(2027, 3, 12)   # Fri before the 14 Mar 2027 change


# ---------------------------------------------------------------- dates (conventions.md table)

@pytest.mark.parametrize("text,ref,want", [
    ("next Thursday", MON, date(2026, 11, 12)),
    ("Friday", MON, date(2026, 11, 6)),
    ("fri", MON, date(2026, 11, 6)),
    ("Monday", MON, date(2026, 11, 9)),            # bare weekday is never today
    ("next Friday", NYE, date(2027, 1, 8)),        # year rollover
    ("tomorrow", NYE, date(2027, 1, 1)),
    ("tmrw", MON, date(2026, 11, 3)),
    ("Monday", PRE_DST, date(2027, 3, 15)),
    ("Nov 20", MON, date(2026, 11, 20)),
    ("the 1st", MON, date(2026, 12, 1)),           # day already passed this month -> next month
    ("11/20", MON, date(2026, 11, 20)),
    ("Jan 4", NYE, date(2027, 1, 4)),
])
def test_future_dates(text, ref, want):
    assert parse_date(text, ref).value == want


@pytest.mark.parametrize("text,want", [
    ("yesterday", date(2026, 11, 1)),
    ("Friday", date(2026, 10, 30)),                # expenses look back, strictly before today
    ("last Monday", date(2026, 10, 26)),
    ("Oct 28", date(2026, 10, 28)),
])
def test_past_dates_for_expenses(text, want):
    assert parse_date(text, MON, past=True).value == want


@pytest.mark.parametrize("text,field", [
    ("Thursday the 6th", "conflict"),              # the 6th is a Friday
    ("lunch Tue or Wed", "which_event"),
    ("coffee sometime", "date"),
    ("next week", "date"),
])
def test_date_clarify(text, field):
    assert parse_date(text, MON).clarify == field


def test_no_date_is_empty_not_a_guess():
    p = parse_date("call mom", MON)
    assert p.value is None and p.clarify is None


def test_friday_followed_by_time_is_not_day_of_month():
    assert parse_date("dinner Friday 7pm", MON).value == date(2026, 11, 6)


# ---------------------------------------------------------------- times

@pytest.mark.parametrize("span,message,want", [
    ("at 7", "dinner Friday at 7?", time(19, 0)),          # meal word -> PM
    ("after 7", "dinner next Thursday after 7", time(19, 0)),
    ("9am", "Monday at 9am standup", time(9, 0)),
    ("19:00", "sync 19:00", time(19, 0)),
    ("at 1", "lunch tmrw at 1", time(13, 0)),
    ("11:30", "lunch Friday 11:30", time(11, 30)),          # lunch window 11:00-15:59
    ("at 8", "breakfast Sat at 8", time(8, 0)),
    ("noon", "call at noon Friday", time(12, 0)),
    ("7p", "drinks fri 7p", time(19, 0)),
])
def test_times(span, message, want):
    assert parse_time(span, message).value.start == want


def test_no_ampm_cue_asks():
    assert parse_time("at 7", "call at 7").clarify == "ampm"


def test_time_range_gives_duration():
    v = parse_time("2-4pm", "workshop Friday 2-4pm").value
    assert v.start == time(14, 0) and v.duration_min == 120


def test_money_is_not_a_time():
    assert parse_time("$20", "lunch $20").value is None


@pytest.mark.parametrize("text,mins", [("for 2 hours", 120), ("30 min", 30), ("90 minutes", 90),
                                       ("half an hour", 30), ("an hour and a half", 90), ("for an hour", 60)])
def test_durations(text, mins):
    assert parse_duration(text).value == mins


# ---------------------------------------------------------------- DST

def test_dst_new_offset():
    assert iso(combine(date(2027, 3, 15), time(9, 0), NY).value) == "2027-03-15T09:00:00-04:00"


def test_dst_skipped_time_asks():
    assert combine(date(2027, 3, 14), time(2, 30), NY).clarify == "invalid_time"


# ---------------------------------------------------------------- amounts

@pytest.mark.parametrize("text,want", [
    ("$23.50", (Decimal("23.50"), "USD")),
    ("$1,200", (Decimal("1200.00"), "USD")),
    ("23 bucks", (Decimal("23.00"), "USD")),
    ("€15", (Decimal("15.00"), "EUR")),
    ("500 rupees", (Decimal("500.00"), "INR")),
    ("$1.2k", (Decimal("1200.00"), "USD")),
])
def test_amounts(text, want):
    assert parse_amount(text).value == want


def test_bare_number_defaults_to_usd_only_when_allowed():
    assert parse_amount("lunch 18").value is None
    assert parse_amount("lunch 18", allow_bare=True).value == (Decimal("18.00"), "USD")


def test_two_amounts_ask():
    assert parse_amount("cab was $40 or $45").clarify == "amount"


# ---------------------------------------------------------------- schema / parser

def test_parse_valid_event_with_code_fence():
    raw = '```json\n{"action":"event","title":"Dinner","start":"2026-11-06T19:00:00-05:00","duration_min":60,' \
          '"spans":{"date":"Friday","time":"at 7","duration":null,"title":"dinner"}}\n```'
    a, err = parse_action(raw)
    assert isinstance(a, Event) and err is None
    assert to_pred("x", a) == {"id": "x", "action": "event", "schema_valid": True,
                               "start": "2026-11-06T19:00:00-05:00", "title": "Dinner", "duration_min": 60}


@pytest.mark.parametrize("raw,why", [
    ("Sure! Here's your event.", "not_json"),
    ('{"action":"event","title":"Dinner","start":"2026-11-06T19:00","duration_min":60}', "start"),  # no offset
    ('{"action":"event","title":"Dinner","start":"2026-11-06T19:00:00-05:00","duration_min":0}', "duration_min"),
    ('{"action":"meeting"}', "action"),
    ('{"action":"clarify","fields":[]}', "fields"),
    ('{"action":"clarify","fields":["mood"]}', "fields"),
    ('{"action":"expense","amount":"12.345","currency":"USD","description":"x","date":"2026-11-02"}', "amount"),
    ('{"action":"expense","amount":"12","currency":"usd","description":"x","date":"2026-11-02"}', "currency"),
    ('{"action":"none","title":"extra"}', "title"),
])
def test_schema_rejects(raw, why):
    a, err = parse_action(raw)
    assert a is None and why in err


def test_expense_amount_number_becomes_exact_decimal():
    a, _ = parse_action('{"action":"expense","amount":23.5,"currency":"USD","description":"lunch","date":"2026-11-01"}')
    assert isinstance(a, Expense) and a.amount == Decimal("23.5")
    assert to_pred("e", a)["amount"] == "23.50"


def test_invalid_output_pred_is_marked():
    assert to_pred("x", None) == {"id": "x", "action": None, "schema_valid": False}
    a, _ = parse_action('{"action":"clarify","fields":["ampm","date"]}')
    assert isinstance(a, Clarify) and to_pred("x", a)["fields"] == ["ampm", "date"]

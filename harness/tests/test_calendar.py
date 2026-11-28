"""Calendar/actions: schema, resolver, parser. Expected values come from conventions.md and the
worked examples in docs/milestone2.pdf (Section 6), not from the resolver itself."""
import sys
from datetime import date, time
from decimal import Decimal
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from calendar_schema import Clarify, Event, Expense, parse_action, to_pred  # noqa: E402
from resolver import combine, iso, parse_amount, parse_date, parse_duration, parse_time, resolve_action  # noqa: E402

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


# ---------------------------------------------------------------- data validator

import copy  # noqa: E402
import json  # noqa: E402

from validate_calendar_data import coverage, validate, validate_item  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
GOOD = {"id": "t", "message": "dinner Friday at 7?", "reference_time": "2026-11-02T10:00:00-05:00",
        "tz": NY, "slice": ["resolve"],
        "gold": {"action": "event", "start": "2026-11-06T19:00:00-05:00", "duration_min": 60,
                 "title_terms": ["dinner"], "spans": {"date": "Friday", "time": "at 7", "duration": None}}}


def _bad(path, value):
    it = copy.deepcopy(GOOD)
    *keys, last = path
    d = it
    for k in keys:
        d = d[k]
    d[last] = value
    return validate_item(it)


def test_validator_accepts_good_item():
    assert validate_item(GOOD) == []


@pytest.mark.parametrize("path,value,expect", [
    (("gold", "start"), "2026-11-06T07:00:00-05:00", "start"),             # wrong AM/PM
    (("gold", "start"), "2026-11-06T19:00:00-04:00", "start"),             # wrong offset
    (("gold", "duration_min"), 30, "duration_min"),
    (("gold", "spans", "date"), "Saturday", "not verbatim"),
    (("gold", "title_terms"), ["lunch"], "not in message"),
    (("reference_time",), "2026-11-02T10:00:00-04:00", "offset"),         # EDT offset in November
])
def test_validator_catches_wrong_gold(path, value, expect):
    errs = _bad(path, value)
    assert errs and any(expect in e for e in errs), errs


def test_validator_catches_clarify_that_conventions_would_resolve():
    it = copy.deepcopy(GOOD)
    it["gold"] = {"action": "clarify", "fields": ["ampm"], "intended": "event", "spans": {"date": "Friday", "time": "at 7"}}
    assert validate_item(it)  # "dinner" is an AM/PM cue, so asking is wrong


def test_validator_flags_duplicates_and_missing_coverage():
    assert any("duplicate" in e for e in validate([GOOD, GOOD]))
    assert any("invalid_time" in p for p in coverage([GOOD]))


def test_dev_pilot_is_valid_and_covered():
    items = [json.loads(line) for line in open(ROOT / "data/dev/calendar_dev.jsonl") if line.strip()]
    assert len(items) == 60
    assert validate(items) == [] and coverage(items) == []


# ---------------------------------------------------------------- B0

import nsdd  # noqa: E402
from b0_calendar import run as b0_run  # noqa: E402


def _item(msg, ref="2026-11-02T10:00:00-05:00"):
    return {"id": "t", "message": msg, "reference_time": ref, "tz": NY, "slice": [], "gold": {}}


@pytest.mark.parametrize("msg,want", [
    ("dinner Friday at 7?", {"action": "event", "start": "2026-11-06T19:00:00-05:00", "duration_min": 60}),
    ("remind me Friday to pay rent", {"action": "reminder", "start": "2026-11-06T09:00:00-05:00"}),
    ("call at 7", {"action": "clarify", "fields": ["date"]}),
    ("spent $23.50 on lunch yesterday", {"action": "expense", "amount": "23.50", "date": "2026-11-01"}),
    ("thanks, see you then!", {"action": "none"}),
])
def test_b0_rules(msg, want):
    pred = b0_run([_item(msg)], detector="rules")[0][0]
    assert {k: pred.get(k) for k in want} == want


def test_b0_titles_only_use_message_words():
    from score_calendar import unsupported_words
    for msg in ["dinner Friday at 7?", "Hey! Want to grab dinner Friday at 7:30? Let me know.", "uber 18 bucks"]:
        p = b0_run([_item(msg)], detector="rules")[0][0]
        assert unsupported_words(p.get("title") or p.get("description"), msg) == []


@pytest.mark.skipif(not nsdd.available(), reason="NSDataDetector needs macOS + pyobjc")
def test_nsdd_finds_date_text_with_correct_offsets():
    msg = "₹500 for the auto, dinner Friday at 7?"
    for m in nsdd.detect_dates(msg):
        assert msg[m.start:m.end] == m.text
    assert any("Friday" in m.text for m in nsdd.detect_dates(msg))


# ---------------------------------------------------------------- C3 verifier

from verify_calendar import check, make_verifier  # noqa: E402

DINNER = _item("dinner Friday at 7?")


def _ev(**over):
    obj = {"action": "event", "title": "Dinner", "start": "2026-11-06T19:00:00-05:00", "duration_min": 60,
           "spans": {"date": "Friday", "time": "at 7", "duration": None, "title": "dinner"}}
    obj.update(over)
    return parse_action(json.dumps(obj))[0]


def test_verifier_passes_correct_event():
    assert check(DINNER, _ev())["ok"]


@pytest.mark.parametrize("over,failed", [
    ({"start": "2026-11-06T07:00:00-05:00"}, "resolve"),                  # AM instead of PM
    ({"start": "2026-11-07T19:00:00-05:00"}, "resolve"),                  # wrong day
    ({"duration_min": 90}, "resolve"),
    ({"spans": {"date": "Saturday", "time": "at 7", "duration": None, "title": "dinner"}}, "span_verbatim"),
    ({"spans": {"date": None, "time": "at 7", "duration": None, "title": "dinner"}}, "spans_present"),
    ({"title": "Dinner at Nobu"}, "title"),
])
def test_verifier_catches_wrong_values(over, failed):
    v = check(DINNER, _ev(**over), span_policy="strict")
    assert not v["ok"] and failed in v["failed"], v
    assert not check(DINNER, _ev(**over))["ok"]  # v2 (default) still rejects every one of these


def test_v2_ignores_spans_copied_from_the_now_line_when_value_is_right():
    # Dev run 1 false alarm: no date in the message; the model's date span came from the "Now:" line.
    item = _item("uber 18 bucks")
    obj = {"action": "expense", "amount": "18.00", "currency": "USD", "description": "uber", "date": "2026-11-02",
           "spans": {"amount": "18 bucks", "date": "Monday, 2 November 2026", "description": "uber"}}
    a = parse_action(json.dumps(obj))[0]
    assert not check(item, a, span_policy="strict")["ok"]
    assert check(item, a)["ok"]
    wrong = parse_action(json.dumps({**obj, "date": "2026-11-01"}))[0]
    assert not check(item, wrong)["ok"]  # the default (today) still has to match


def test_v2_reads_date_and_time_from_both_spans():
    # Dev run 1 false alarm: time words filed under the date span.
    item = _item("remind me tomorrow at noon to call grandma", "2026-12-31T20:00:00-05:00")
    obj = {"action": "reminder", "title": "call grandma", "start": "2027-01-01T12:00:00-05:00",
           "spans": {"date": "tomorrow at noon", "time": "call grandma", "title": "call grandma"}}
    a = parse_action(json.dumps(obj))[0]
    assert not check(item, a, span_policy="strict")["ok"]
    assert check(item, a)["ok"]


def test_verifier_asks_when_conventions_say_ask():
    v = check(_item("call at 7"), _ev(title="call", spans={"date": None, "time": "at 7", "duration": None, "title": "call"}))
    assert not v["ok"] and v["clarify_field"] in ("date", "ampm")


def test_verifier_checks_expense_amount_against_text():
    item = _item("spent $23.50 on lunch yesterday")
    good = {"action": "expense", "amount": "23.50", "currency": "USD", "description": "lunch", "date": "2026-11-01",
            "spans": {"amount": "$23.50", "date": "yesterday", "description": "lunch"}}
    assert check(item, parse_action(json.dumps(good))[0])["ok"]
    bad = check(item, parse_action(json.dumps({**good, "amount": "25.30"}))[0])
    assert not bad["ok"] and bad["clarify_field"] == "amount"


def test_verifier_leaves_none_and_clarify_alone():
    assert check(DINNER, parse_action('{"action":"none"}')[0])["ok"]
    assert check(DINNER, parse_action('{"action":"clarify","fields":["date"]}')[0])["ok"]


def test_recovery_options():
    wrong = _ev(start="2026-11-06T07:00:00-05:00")
    a, v = make_verifier({"verifier": {"recovery": "clarify"}})(DINNER, wrong)
    assert a.action == "clarify" and v["recovery"] == "clarify"
    a, v = make_verifier({"verifier": {"recovery": "b0"}})(DINNER, wrong)
    assert a.action == "event" and a.start.isoformat() == "2026-11-06T19:00:00-05:00" and v["recovery"] == "b0"
    a, v = make_verifier({"verifier": {"recovery": "repair"}})(DINNER, wrong)
    assert a is wrong and v["recovery"] == "repair_pending"


# ---------------------------------------------------------------- C1 grammar (needs the model file)

MODEL = ROOT / "models/Llama-3.2-3B-Instruct-Q4_K_M.gguf"


@pytest.mark.skipif(not MODEL.exists(), reason="model weights not downloaded")
def test_grammar_forces_schema_valid_output_even_off_task():
    # LlamaGrammar.from_file does NOT raise on a bad grammar (it logs and returns an unusable one),
    # so the only real check is generating with it.
    from llama_cpp import Llama, LlamaGrammar
    llm = Llama(model_path=str(MODEL), n_ctx=1024, n_gpu_layers=-1, seed=0, verbose=False)
    grammar = LlamaGrammar.from_file(str(ROOT / "schemas/calendar.gbnf"), verbose=False)
    for prompt in ["Say hello in French.", "dinner Friday at 7? Today is Mon 2 Nov 2026, America/New_York."]:
        out = llm.create_chat_completion(messages=[{"role": "user", "content": prompt}], temperature=0,
                                         max_tokens=200, grammar=grammar)["choices"][0]["message"]["content"]
        action, err = parse_action(out)
        assert err is None, (prompt, out, err)


def test_repeated_clarify_fields_are_dropped_not_rejected():
    a, err = parse_action('{"action":"clarify","fields":["date","date","ampm"]}')
    assert err is None and a.fields == ["date", "ampm"]


def test_validator_review_mode_flags_resolve_disagreements_without_failing(tmp_path):
    import subprocess
    disagree = copy.deepcopy(GOOD)
    disagree["gold"]["start"] = "2026-11-06T18:00:00-05:00"      # a person may read it differently
    f = tmp_path / "x.jsonl"
    f.write_text(json.dumps(disagree) + "\n")
    script = str(ROOT / "harness/validate_calendar_data.py")
    run = lambda mode: subprocess.run([sys.executable, script, "--items", str(f), "--mode", mode, "--no-coverage"],
                                      capture_output=True, text=True)
    assert run("strict").returncode == 1
    r = run("review")
    assert r.returncode == 0 and "NEEDS HUMAN CHECK" in r.stdout
    broken = copy.deepcopy(GOOD)
    broken["gold"]["spans"]["date"] = "Saturday"                 # structural: still fails
    f.write_text(json.dumps(broken) + "\n")
    assert run("review").returncode == 1


# ---------------------------------------------------------------- cloud runner: quota and resume

from run_calendar import GeminiModel, QuotaExhausted, _retry_delay_s, run as run_items  # noqa: E402


class _QuotaError(Exception):
    code, status, message = 429, "RESOURCE_EXHAUSTED", "Quota exceeded: requests per day"
    details = {"error": {"details": [{"@type": "type.googleapis.com/google.rpc.RetryInfo", "retryDelay": "39834s"}]}}


def test_retry_delay_parsed():
    assert _retry_delay_s(_QuotaError()) == 39834.0
    assert _retry_delay_s(Exception()) is None


def test_daily_quota_stops_run_instead_of_burning_requests():
    calls = []

    class Fake:
        name = "fake"

        def __call__(self, system, user, ref=None):
            calls.append(1)
            raise QuotaExhausted("429: quota resets in 11.1 h")

    items = [_item("dinner Friday at 7?"), {**_item("uber 18 bucks"), "id": "t2"}]
    preds, traj = run_items(items, Fake(), "sys", {"name": "cloud"})
    assert preds == [] and len(calls) == 1


def test_scorer_refuses_runs_with_infrastructure_errors(tmp_path):
    import subprocess
    pred = tmp_path / "p.jsonl"
    pred.write_text(json.dumps({"id": "cal-001", "action": None, "schema_valid": False, "error": "503 UNAVAILABLE"}) + "\n")
    r = subprocess.run([sys.executable, str(ROOT / "eval/score_calendar.py"), "--gold",
                        str(ROOT / "data/dev/calendar_dev.jsonl"), "--pred", str(pred)], capture_output=True, text=True)
    assert r.returncode != 0 and "Refusing to score" in (r.stderr + r.stdout)


# ---------------------------------------------------------------- notes C3 verifier

def test_notes_verifier_catches_wrong_number_and_passes_supported_answer():
    from verify_notes import check
    notes = {"n-010": {"body": "Bike lock combo 0629."}, "n-002": {"body": "Rent is 1200 dollars, due on the 1st."}}
    ret = [{"note_id": "n-010", "score": 0.03}, {"note_id": "n-002", "score": 0.02}]
    bad = check("62-9", [{"note_id": "n-010", "quote": "Bike lock combo 0629."}], ret, notes, 0.0, "quote")
    assert not bad["ok"] and bad["failed"] == ["grounded"]
    good = check("0629", [{"note_id": "n-010", "quote": "Bike lock combo 0629."}], ret, notes, 0.0, "quote")
    assert good["ok"]
    # "$1,200" vs "1200 dollars": reformatted numbers are not false alarms
    assert check("$1,200, due on the 1st", [{"note_id": "n-002", "quote": "Rent is 1200 dollars, due on the 1st."}],
                 ret, notes, 0.0, "quote")["ok"]


def test_notes_verifier_quote_grounding_and_other_checks():
    from verify_notes import check
    notes = {"n-004": {"body": "Home wifi: network ApartmentDsix, password tangerine-4471."}}
    ret = [{"note_id": "n-004", "score": 0.03}]
    short = [{"note_id": "n-004", "quote": "Home wifi"}]
    assert not check("tangerine-4471", short, ret, notes, 0.0, "quote")["ok"]   # v1: the quote must hold it
    assert check("tangerine-4471", short, ret, notes, 0.0, "note")["ok"]         # v2: the cited note holds it
    assert check("the notes don't say", [], ret, notes, 0.0, "quote")["ok"]      # abstentions pass through
    assert "cited" in check("tangerine-4471", [], ret, notes, 0.0, "note")["failed"]
    assert "quote" in check("x", [{"note_id": "n-004", "quote": "made up"}], ret, notes, 0.0, "note")["failed"]
    assert "cited" in check("x", [{"note_id": "n-999", "quote": "Home wifi"}], ret, notes, 0.0, "note")["failed"]
    assert "retrieval" in check("tangerine-4471", short, ret, notes, 0.05, "note")["failed"]
    # names must be grounded too
    assert "grounded" in check("Ask Marcus for it", short, ret, notes, 0.0, "note")["failed"]


def test_resume_with_limit_keeps_earlier_items(tmp_path, monkeypatch):
    """--resume --limit 1 runs one new item and keeps every item already done (it once truncated)."""
    import sys
    import run_calendar as rc
    out = str(tmp_path / "run")
    items = [json.loads(l) for l in open(rc.ROOT / "data/dev/calendar_dev.jsonl")][:4]
    (tmp_path / "items.jsonl").write_text("".join(json.dumps(i) + "\n" for i in items))
    done = [{"id": i["id"], "action": "none", "schema_valid": True} for i in items[:2]]
    (tmp_path / "run_pred.jsonl").write_text("".join(json.dumps(p) + "\n" for p in done))
    (tmp_path / "run_trajectory.jsonl").write_text("".join(json.dumps({"id": p["id"], "schema_valid": True}) + "\n" for p in done))

    class Fake:
        name = "fake"
        def __init__(self, *a, **k): pass
        def __call__(self, system, user, ref=None):
            return '{"action": "none"}', {"total_ms": 1.0, "first_token_ms": 1.0}
    monkeypatch.setattr(rc, "LocalModel", Fake)
    monkeypatch.setattr(sys, "argv", ["run_calendar.py", "--config", str(rc.ROOT / "configs/C1.yaml"),
                                      "--items", str(tmp_path / "items.jsonl"), "--out", out, "--resume", "--limit", "1"])
    rc.main()
    ids = [json.loads(l)["id"] for l in open(out + "_pred.jsonl")]
    assert ids == [i["id"] for i in items[:3]]


# ---------------------------------------------------------------- convention fixes (2026-11-25)

@pytest.mark.parametrize("text,past,want", [
    ("drinks fri or sat", False, "which_event"),          # bug: lowercase alternative was dropped
    ("coffee wed or thurs", False, "which_event"),
    ("sat/sun brunch", False, "which_event"),
    ("the sun is out", False, None),                      # still not a weekday
    ("Friday next week", False, "2026-11-13"),            # bug: was the coming Friday
    ("a week from Friday", False, "2026-11-13"),
    ("in 3 days", False, "2026-11-05"),
    ("in two weeks", False, "2026-11-16"),
    ("11-20", False, "2026-11-20"),
    ("11.20", False, None),                               # a price: "." dates need a year
    ("11.20.26", False, "2026-11-20"),
    ("coffee 4.75", False, None),                         # was read as April 75 (B0 regression)
    ("4-75", False, None),
    ("2-4pm", False, None),                               # a time range, not 4 Feb
    ("$11.20", False, None),
    ("1.5 hours", False, None),
    ("3 days ago", True, "2026-10-30"),
])
def test_new_date_rules(text, past, want):
    from datetime import date
    p = parse_date(text, date(2026, 11, 2), past)
    got = p.value.isoformat() if p.value else p.clarify
    assert got == want


@pytest.mark.parametrize("text,want", [
    ("tonight 7", "19:00"), ("this evening 8", "20:00"), ("meet 3 people tonight", None),
    ("half past 6 dinner", "18:30"), ("quarter past 9 breakfast", "09:15"), ("quarter to 7 dinner", "18:45"),
    ("half past 6", "ampm"), ("2-4pm", "14:00"),
])
def test_new_time_rules(text, want):
    p = parse_time(text, text)
    got = p.value.start.strftime("%H:%M") if p.value else p.clarify
    assert got == want


def test_cad_aud_symbols_and_evening_reminder():
    assert parse_amount("C$20").value[1] == "CAD"        # bug: was USD
    assert parse_amount("A$15").value[1] == "AUD"
    assert parse_amount("$20").value[1] == "USD"
    r = resolve_action("reminder", {"date": "tomorrow evening"}, "remind me tomorrow evening to call mom",
                       "2026-11-02T10:00:00-05:00", "America/New_York")
    assert r.clarify == "start_time"
    r = resolve_action("reminder", {"date": "tomorrow"}, "remind me to buy drinks tomorrow",
                       "2026-11-02T10:00:00-05:00", "America/New_York")
    assert r.value["start"] == "2026-11-03T09:00:00-05:00"


def test_recompute_replaces_model_date_with_code_value():
    """C3 + code values: a wrong model date becomes the conventions' date; title and spans kept."""
    from verify_calendar import recompute
    item = {"id": "x", "message": "dinner Friday at 7", "reference_time": "2026-11-02T10:00:00-05:00", "tz": "America/New_York"}
    a, _ = parse_action('{"action": "event", "title": "dinner", "start": "2026-11-05T19:00:00-05:00", "duration_min": 60, '
                        '"spans": {"date": "Friday", "time": "at 7", "duration": null, "title": "dinner"}}')
    final, v = recompute(item, a)
    assert v["ok"] and v["replaced"] == ["start"]
    assert final.start.isoformat() == "2026-11-06T19:00:00-05:00" and final.title == "dinner"
    a2, _ = parse_action('{"action": "event", "title": "dinner", "start": "2026-11-05T19:00:00-05:00", "duration_min": 60, '
                         '"spans": {"date": null, "time": "at 7", "duration": null, "title": "dinner"}}')
    final2, v2 = recompute({**item, "message": "dinner at 7"}, a2)
    assert final2.action == "clarify" and final2.fields == ["date"]


# ---------------------------------------------------------------- real-data intake

def test_intake_flags_personal_details_and_accepts_placeholders():
    from intake_real import maybe_names, problems
    found = problems("call Priya at 917-555-0142 or priya@x.com, 340 E 23rd St, card 4111 1111 1111 1111", ["Priya"])
    kinds = {f.split(":")[0] for f in found}
    assert {"phone number", "email address", "street address", "long number (card/account)", "listed name"} <= kinds
    assert problems("dinner w <NAME> fri at 7, paid $12.50 on 11/20", ["Priya"]) == []
    assert "NAME" not in maybe_names("dinner w <NAME> fri at 7")


def test_recompute_reads_message_when_model_copies_the_now_line():
    """The model's date span came from the prompt's "Now:" line (not in the message) and its time
    span "7" names no date: code reads the date and time from the message itself."""
    from verify_calendar import recompute
    item = {"id": "x", "message": "Dinner with Sam Friday at 7", "reference_time": "2026-11-27T21:33:00-05:00",
            "tz": "America/New_York"}
    a, _ = parse_action('{"action": "event", "title": "Dinner with Sam", "start": "2026-11-26T19:00:00-05:00", '
                        '"duration_min": 60, "spans": {"date": "Friday, 27 November 2026", "time": "7", '
                        '"duration": "60 minutes", "title": "Dinner with Sam"}}')
    final, v = recompute(item, a)
    assert final.action == "event" and final.start.isoformat() == "2026-12-04T19:00:00-05:00"

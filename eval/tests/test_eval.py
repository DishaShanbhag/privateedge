import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from bootstrap_gap import paired_bootstrap  # noqa: E402
from hash_testset import hash_dir  # noqa: E402
from score_calendar import score_item  # noqa: E402

EVENT = {"message": "dinner Friday at 7?", "gold": {"action": "event", "start": "2026-11-06T19:00:00-05:00", "duration_min": 60, "title_terms": ["dinner"]}}
CLARIFY = {"message": "call at 7", "gold": {"action": "clarify", "fields": ["ampm", "date"]}}
DST = {"message": "Monday at 9am standup", "gold": {"action": "event", "start": "2027-03-15T09:00:00-04:00", "duration_min": 60, "title_terms": ["standup"]}}


def test_correct_event():
    pred = {"action": "event", "start": "2026-11-06T19:00:00-05:00", "duration_min": 60, "title": "Dinner"}
    assert score_item(EVENT, pred) == (1, "ok")


def test_wrong_offset_is_wrong():
    # Same wall-clock time but the pre-DST offset: a different instant.
    pred = {"action": "event", "start": "2027-03-15T09:00:00-05:00", "duration_min": 60, "title": "standup"}
    assert score_item(DST, pred)[0] == 0


def test_acting_on_clarify_item_is_wrong():
    pred = {"action": "event", "start": "2026-11-02T19:00:00-05:00", "duration_min": 60, "title": "call"}
    assert score_item(CLARIFY, pred) == (0, "acted_on_clarify")


def test_clarify_must_name_a_missing_field():
    assert score_item(CLARIFY, {"action": "clarify", "fields": ["ampm"]}) == (1, "ok")
    assert score_item(CLARIFY, {"action": "clarify", "fields": ["which_event"]})[0] == 0


def test_unneeded_clarify_is_wrong():
    assert score_item(EVENT, {"action": "clarify", "fields": ["date"]}) == (0, "unneeded_clarify")


def test_missing_title_term():
    pred = {"action": "event", "start": "2026-11-06T19:00:00-05:00", "duration_min": 60, "title": "Meeting"}
    assert score_item(EVENT, pred) == (0, "missing_title_term")


def test_bootstrap_zero_gap():
    scores = {str(i): float(i % 2) for i in range(100)}
    gap, lo, hi, k = paired_bootstrap(scores, dict(scores), n=500)
    assert k == 100 and gap == 0 and lo == 0 and hi == 0


def test_bootstrap_known_gap():
    local = {str(i): 0.0 if i < 10 else 1.0 for i in range(100)}
    cloud = {str(i): 1.0 for i in range(100)}
    gap, lo, hi, _ = paired_bootstrap(local, cloud, n=2000)
    assert abs(gap - 10.0) < 1e-9 and lo < 10 < hi


def test_hash_is_stable_and_detects_changes(tmp_path):
    (tmp_path / "a.jsonl").write_text("x\n")
    (tmp_path / "README.md").write_text("ignored")
    h1 = hash_dir(tmp_path)
    assert h1 == hash_dir(tmp_path)
    (tmp_path / "README.md").write_text("still ignored")
    assert h1 == hash_dir(tmp_path)
    (tmp_path / "a.jsonl").write_text("y\n")
    assert h1 != hash_dir(tmp_path)


# ---------------------------------------------------------------- calendar scorer: new actions and reports

from score_calendar import field_results, score_all, unsupported_words  # noqa: E402

EXPENSE = {"message": "spent $23.50 on lunch yesterday", "slice": ["expense"],
           "gold": {"action": "expense", "amount": "23.50", "currency": "USD", "date": "2026-11-01", "description_terms": ["lunch"]}}
NONE = {"message": "thanks, see you then!", "slice": ["none"], "gold": {"action": "none"}}
GOOD_EXP = {"action": "expense", "amount": "23.50", "currency": "USD", "date": "2026-11-01", "description": "Lunch"}


def test_expense_exact_match_and_each_failure():
    assert score_item(EXPENSE, GOOD_EXP) == (1, "ok")
    assert score_item(EXPENSE, {**GOOD_EXP, "amount": "23.5"})[1] == "wrong_amount"
    assert score_item(EXPENSE, {**GOOD_EXP, "currency": "EUR"})[1] == "wrong_currency"
    assert score_item(EXPENSE, {**GOOD_EXP, "date": "2026-11-02"})[1] == "wrong_date"
    assert score_item(EXPENSE, {**GOOD_EXP, "description": "Lunch at Joe's"})[1] == "unsupported_title_word"


def test_none_item():
    assert score_item(NONE, {"action": "none"}) == (1, "ok")
    assert score_item(NONE, {"action": "event", "start": "2026-11-02T19:00:00-05:00"})[1] == "acted_on_none"
    assert score_item(NONE, {"action": "clarify", "fields": ["date"]})[1] == "unneeded_clarify"


def test_schema_invalid_is_wrong():
    assert score_item(EVENT, {"action": None, "schema_valid": False}) == (0, "schema_invalid")


def test_invented_title_word_is_wrong_but_typos_dates_and_function_words_are_not():
    assert unsupported_words("Dinner with Sam", "dinner Friday at 7?") == ["sam"]
    assert unsupported_words("Dinner with the team on Friday 7pm", "dinnr w the team friday at 7") == []
    pred = {"action": "event", "start": "2026-11-06T19:00:00-05:00", "duration_min": 60, "title": "Dinner at Nobu"}
    assert score_item(EVENT, pred) == (0, "unsupported_title_word")


def test_field_results_separate_date_from_time_and_offset():
    pred = {"action": "event", "start": "2026-11-06T07:00:00-05:00", "duration_min": 60, "title": "dinner"}
    assert field_results(EVENT, pred) == {"action": 1, "date": 1, "time": 0, "title": 1, "duration": 1}
    dst = {"action": "event", "start": "2027-03-15T09:00:00-05:00", "duration_min": 60, "title": "standup"}
    assert field_results(DST, dst)["time"] == 0  # same wall clock, wrong offset
    assert field_results(EXPENSE, {"action": "event"})["amount"] == 0


def test_score_all_subsets_and_schema_rate():
    gold = {"e": EVENT, "x": EXPENSE, "n": NONE, "c": {**CLARIFY, "slice": ["clarify"]}}
    pred = {"e": {"id": "e", "action": "event", "schema_valid": True, "start": "2026-11-06T19:00:00-05:00",
                  "duration_min": 60, "title": "Dinner"},
            "x": {"id": "x", "action": None, "schema_valid": False},
            "n": {"id": "n", "action": "none", "schema_valid": True}}
    rows, by_slice, fields, valid = score_all(gold, pred)
    byid = {r["id"]: r for r in rows}
    assert valid == 2 and byid["c"]["reason"] == "missing"
    assert [r["id"] for r in rows if r["events_reminders"]] == ["e", "c"]
    assert sum(r["score"] for r in rows) == 2 and by_slice["expense"] == [0]


def test_bootstrap_subset_column(tmp_path):
    from bootstrap_gap import read
    (tmp_path / "s.csv").write_text("id,score,reason,events_reminders\na,1,ok,1\nb,0,wrong_amount,0\n")
    assert read(tmp_path / "s.csv") == {"a": 1.0, "b": 0.0}
    assert read(tmp_path / "s.csv", "events_reminders") == {"a": 1.0}

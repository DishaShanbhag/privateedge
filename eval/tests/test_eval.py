import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from bootstrap_gap import paired_bootstrap  # noqa: E402
from hash_testset import hash_dir  # noqa: E402
from score_calendar import score_item  # noqa: E402

EVENT = {"gold": {"action": "event", "start": "2026-11-06T19:00:00-05:00", "duration_min": 60, "title_terms": ["dinner"]}}
CLARIFY = {"gold": {"action": "clarify", "fields": ["ampm", "date"]}}
DST = {"gold": {"action": "event", "start": "2027-03-15T09:00:00-04:00", "duration_min": 60, "title_terms": ["standup"]}}


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

import csv
import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from notes_grading import cohen_kappa, do_import, export, read_scores  # noqa: E402

ITEMS = [
    {"id": "q1", "question": "Wifi password?", "gold": {"answerable": True, "answer": "abc", "key_facts": ["abc"], "support": ["n1"]}},
    {"id": "q2", "question": "Blood type?", "gold": {"answerable": False, "answer": "the notes don't say", "key_facts": [], "support": []}},
    {"id": "q3", "question": "Desk width and colour?", "gold": {"answerable": "partial", "answer": "120cm", "key_facts": ["120cm"],
                                                                 "unsupported_part": "colour", "support": ["n2"]}},
]
CORPUS = [{"id": "n1", "title": "Wifi", "body": "password abc"}, {"id": "n2", "title": "Desk", "body": "120cm wide"}]
CIT = [{"note_id": "n1", "quote": "password abc"}]
RUNS = {
    "C2": [{"id": "q1", "answer": "abc", "citations": CIT}, {"id": "q2", "answer": "the notes don't say", "citations": []},
           {"id": "q3", "answer": "120cm", "citations": [{"note_id": "n2", "quote": "120cm wide"}]}],
    "C3": [{"id": "q1", "answer": "abc", "citations": CIT}, {"id": "q2", "answer": "O positive", "citations": []},
           {"id": "q3", "answer": "the notes don't say", "citations": []}],
}


def _sheet(path):
    with open(path, newline="") as f:
        return list(csv.DictReader(f))


def _fill(rows, path, score_of):
    with open(path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader()
        for r in rows:
            w.writerow({**r, "score": score_of(r)})


def test_export_merges_identical_answers_auto_scores_and_hides_systems(tmp_path):
    s = export(ITEMS, CORPUS, RUNS, tmp_path, double_frac=0.5)
    sheet = _sheet(tmp_path / "grading_sheet_first.csv")
    # q1: same answer from both systems -> 1 row; q3: two different answers -> 2 rows; q2 auto-scored.
    assert s["rows_to_grade"] == 3 and s["answers_covered_by_rows"] == 4 and s["auto_scored"] == 2
    text = (tmp_path / "grading_sheet_first.csv").read_text() + (tmp_path / "grading_sheet_second.csv").read_text()
    assert "C2" not in text and "C3" not in text
    assert any("[n1] Wifi: password abc" in r["cited_notes"] for r in sheet)
    key = json.loads((tmp_path / "grading_key.json").read_text())
    assert key["auto"]["C2"]["q2"][0] == 2 and key["auto"]["C3"]["q2"][0] == 0
    assert len(key["second_rows"]) == 2 and len(_sheet(tmp_path / "grading_sheet_second.csv")) == 2


def test_import_round_trip_writes_per_system_scores(tmp_path):
    export(ITEMS, CORPUS, RUNS, tmp_path, double_frac=0.5)
    first = _sheet(tmp_path / "grading_sheet_first.csv")
    score = lambda r: 0 if "don't say" in r["answer"] else (1 if r["answerable"] == "partial" else 2)
    _fill(first, tmp_path / "g1.csv", score)
    _fill(_sheet(tmp_path / "grading_sheet_second.csv"), tmp_path / "g2.csv", score)
    res = do_import(tmp_path, tmp_path / "g1.csv", tmp_path / "g2.csv")
    assert res["unresolved"] == 0 and res["kappa"] == 1.0
    read = lambda s: {r["id"]: int(r["score"]) for r in csv.DictReader(open(tmp_path / f"{s}_notes_scores.csv"))}
    assert read("C2") == {"q1": 2, "q2": 2, "q3": 1}
    assert read("C3") == {"q1": 2, "q2": 0, "q3": 0}


def test_disagreements_need_adjudication(tmp_path):
    export(ITEMS, CORPUS, RUNS, tmp_path, double_frac=1.0)
    rows = _sheet(tmp_path / "grading_sheet_first.csv")
    _fill(rows, tmp_path / "g1.csv", lambda r: 2)
    _fill(rows, tmp_path / "g2.csv", lambda r: 1)
    res = do_import(tmp_path, tmp_path / "g1.csv", tmp_path / "g2.csv")
    assert res["unresolved"] == 3 and not (tmp_path / "C2_notes_scores.csv").exists()
    adj = _sheet(tmp_path / "to_adjudicate.csv")
    with open(tmp_path / "adj.csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(adj[0].keys()))
        w.writeheader()
        w.writerows({**r, "score": 1} for r in adj)
    res = do_import(tmp_path, tmp_path / "g1.csv", tmp_path / "g2.csv", tmp_path / "adj.csv")
    assert res["unresolved"] == 0 and (tmp_path / "C2_notes_scores.csv").exists()


def test_kappa_and_score_validation(tmp_path):
    assert cohen_kappa([0, 0, 1, 1], [0, 1, 0, 1]) == 0.0
    assert cohen_kappa([0, 1, 2, 2], [0, 1, 2, 2], weights="quadratic") == 1.0
    assert 0 < cohen_kappa([0, 1, 2, 2], [0, 1, 1, 2], weights="quadratic") < 1
    bad = tmp_path / "bad.csv"
    bad.write_text("row_id,score\nG0001,3\n")
    with pytest.raises(SystemExit):
        read_scores(bad, {"G0001"})

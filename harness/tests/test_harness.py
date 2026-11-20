import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from b0_notes import ABSTAIN, best_sentence, run, sentences  # noqa: E402
from metrics import abstention_report, retrieval_report  # noqa: E402
from retrieval import BM25Index, query_terms  # noqa: E402
from validate_notes_data import validate  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
NOTES = [
    {"id": "n-1", "title": "Dr. Patel", "body": "Dr. Patel, Tue 3pm. Bring insurance card.", "created": "2026-10-28"},
    {"id": "n-2", "title": "Wifi", "body": "Home wifi password tangerine-4471.", "created": "2026-09-02"},
]


def test_query_terms_drop_stopwords_and_possessives():
    assert query_terms("When is my doctor's appointment?") == ["doctor", "appointment"]


def test_query_with_fts5_operators_does_not_crash():
    idx = BM25Index(NOTES)
    assert idx.search('wifi AND "password" OR NEAR(*)', k=3)[0].note_id == "n-2"


def test_search_ranks_matching_note_first_and_returns_nothing_without_terms():
    idx = BM25Index(NOTES)
    assert idx.search("what's the wifi password?", k=3)[0].note_id == "n-2"
    assert idx.search("what is it?", k=3) == []


def test_sentences_keep_abbreviations():
    assert sentences("Dr. Patel, Tue 3pm. Bring insurance card.") == ["Dr. Patel, Tue 3pm.", "Bring insurance card."]


def test_best_sentence_picks_overlap():
    assert best_sentence(NOTES[0]["body"], "What should I bring?") == "Bring insurance card."


def test_b0_abstains_below_threshold_and_quotes_verbatim_above():
    idx = BM25Index(NOTES)
    items = [{"id": "q1", "question": "wifi password?", "slice": [], "gold": {"answerable": True, "support": ["n-2"]}}]
    preds, traj = run(items, idx, threshold=1e9)
    assert preds[0]["answer"] == ABSTAIN and preds[0]["abstained"]
    preds, traj = run(items, idx, threshold=0)
    assert preds[0]["citations"][0]["quote"] in NOTES[1]["body"]
    assert traj[0]["retrieval_hit"] and traj[0]["quote_from_retrieved"]


def test_metrics():
    items = [
        {"id": "a", "slice": ["two_note"], "gold": {"answerable": True, "support": ["n-1", "n-2"]}},
        {"id": "u", "slice": ["unanswerable"], "gold": {"answerable": False, "support": []}},
    ]
    r = retrieval_report(items, {"a": ["n-1", "n-9", "n-8"]})
    assert r["two_note"]["hit@3"] == 1.0 and r["two_note"]["all@3"] == 0.0
    a = abstention_report(items, {"a": True, "u": True})
    assert a["abstain_recall"] == 1.0 and a["wrongly_abstained"] == 1


def test_validator_flags_bad_items_and_passes_dev_pilot():
    bad = [{"id": "x", "slice": ["lookup"], "gold": {"answerable": True, "answer": "y", "key_facts": ["nope"], "support": ["n-404"]}}]
    errs = validate(bad, NOTES)
    assert any("missing note" in e for e in errs)
    import json
    load = lambda p: [json.loads(l) for l in open(ROOT / p) if l.strip()]
    assert validate(load("data/dev/notes_dev.jsonl"), load("data/dev/notes_corpus.jsonl")) == []


def test_hybrid_rrf_fuses_rankings():
    from retrieval import Hit, HybridIndex

    class Fixed:
        def __init__(self, order):
            self.order = order
        def search(self, q, k):
            return [Hit(i, 1.0, "", "") for i in self.order[:k]]

    bm25, dense = Fixed(["n-1", "n-2"]), Fixed(["n-2", "n-3"])
    bm25.notes = {i: {"title": "", "body": ""} for i in ["n-1", "n-2", "n-3"]}
    top = HybridIndex(bm25, dense).search("q", k=3)
    # n-2 is in both rankings, so it wins; n-1 (rank 1 in BM25) beats n-3 (rank 2 in dense).
    assert [h.note_id for h in top] == ["n-2", "n-1", "n-3"]


def test_build_retriever_bm25_needs_no_model():
    from retrieval import BM25Index, build_retriever
    idx = build_retriever({"notes_retrieval": {"method": "bm25", "top_k": 3}}, str(ROOT / "data/dev/notes_corpus.jsonl"))
    assert isinstance(idx, BM25Index)


def test_render_llama32_pins_the_reference_date():
    from datetime import datetime
    from chat_prompt import render_llama32
    p = render_llama32(" SYS ", "USER\n", datetime.fromisoformat("2026-11-02T10:00:00-05:00"))
    assert p == ("<|begin_of_text|><|start_header_id|>system<|end_header_id|>\n\n"
                 "Cutting Knowledge Date: December 2023\nToday Date: 02 Nov 2026\n\n"
                 "SYS<|eot_id|><|start_header_id|>user<|end_header_id|>\n\nUSER<|eot_id|>"
                 "<|start_header_id|>assistant<|end_header_id|>\n\n")

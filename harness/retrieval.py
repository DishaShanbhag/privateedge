"""BM25 keyword retrieval over the notes corpus, using SQLite FTS5.

The iOS app uses the same engine (SQLite FTS5 with the same tokenizer and query rules), so
scores and rankings carry over from the Mac to the phone.

    idx = BM25Index.from_jsonl("data/dev/notes_corpus.jsonl")
    hits = idx.search("When is my doctor's appointment?", k=3)
"""
import json
import re
import sqlite3
from dataclasses import dataclass

TOKENIZER = "porter unicode61"

# Question words and fillers that carry no topic. Kept short on purpose: BM25's IDF already
# discounts common words, and over-filtering hurts short questions.
STOPWORDS = frozenset("""
a an and are at be did do does for from had has have how i i'm in is it its me my of on or
should the to was what what's when where which who who's whom why will with you your
""".split())


@dataclass
class Hit:
    note_id: str
    score: float  # higher is better (FTS5's bm25() is negated)
    title: str
    body: str


def query_terms(question: str) -> list[str]:
    words = re.findall(r"[a-z0-9]+(?:'[a-z]+)?", question.lower())
    terms = []
    for w in words:
        w = w.split("'")[0]  # "doctor's" -> "doctor"
        if w and w not in STOPWORDS and w not in terms:
            terms.append(w)
    return terms


class BM25Index:
    def __init__(self, notes: list[dict]):
        self.notes = {n["id"]: n for n in notes}
        self.db = sqlite3.connect(":memory:")
        self.db.execute(f"CREATE VIRTUAL TABLE notes USING fts5(id UNINDEXED, title, body, tokenize='{TOKENIZER}')")
        self.db.executemany("INSERT INTO notes VALUES (?, ?, ?)", [(n["id"], n["title"], n["body"]) for n in notes])

    @classmethod
    def from_jsonl(cls, path: str) -> "BM25Index":
        with open(path) as f:
            return cls([json.loads(line) for line in f if line.strip()])

    def search(self, question: str, k: int = 3) -> list[Hit]:
        terms = query_terms(question)
        if not terms:
            return []
        match = " OR ".join(f'"{t}"' for t in terms)  # quoted: no FTS5 operator injection
        rows = self.db.execute(
            "SELECT id, -bm25(notes) AS score, title, body FROM notes WHERE notes MATCH ? "
            "ORDER BY score DESC, id LIMIT ?",
            (match, k),
        ).fetchall()
        return [Hit(*r) for r in rows]

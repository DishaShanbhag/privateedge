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


# ---------------------------------------------------------------------------------------------
# Dense and hybrid retrieval (C2). The embedding model is a small GGUF run by llama.cpp, so the
# phone needs no second runtime. Notes are embedded once at index time; questions at query time.

class DenseIndex:
    def __init__(self, notes: list[dict], model_path: str, query_prefix: str = "", doc_prefix: str = ""):
        from llama_cpp import Llama
        self.notes = {n["id"]: n for n in notes}
        self.ids = [n["id"] for n in notes]
        self.query_prefix = query_prefix
        self.llm = Llama(model_path=model_path, embedding=True, n_gpu_layers=-1, n_ctx=512, verbose=False)
        self.doc_vecs = [self._embed(doc_prefix + f"{n['title']}. {n['body']}") for n in notes]

    def _embed(self, text: str) -> list[float]:
        v = self.llm.embed(text)
        if v and isinstance(v[0], list):  # some models return one vector per token: mean-pool
            v = [sum(col) / len(v) for col in zip(*v)]
        norm = sum(x * x for x in v) ** 0.5 or 1.0
        return [x / norm for x in v]

    def search(self, question: str, k: int = 3) -> list[Hit]:
        q = self._embed(self.query_prefix + question)
        scored = sorted(((sum(a * b for a, b in zip(q, d)), i) for i, d in zip(self.ids, self.doc_vecs)),
                        key=lambda t: (-t[0], t[1]))
        return [Hit(i, s, self.notes[i]["title"], self.notes[i]["body"]) for s, i in scored[:k]]


class HybridIndex:
    """Reciprocal rank fusion of BM25 and dense rankings: score = sum 1 / (rrf_k + rank)."""

    def __init__(self, bm25: BM25Index, dense: DenseIndex, rrf_k: int = 60, candidates: int = 10):
        self.bm25, self.dense, self.rrf_k, self.candidates = bm25, dense, rrf_k, candidates
        self.notes = bm25.notes

    def search(self, question: str, k: int = 3) -> list[Hit]:
        fused: dict[str, float] = {}
        for ranking in (self.bm25.search(question, self.candidates), self.dense.search(question, self.candidates)):
            for rank, h in enumerate(ranking, 1):
                fused[h.note_id] = fused.get(h.note_id, 0.0) + 1.0 / (self.rrf_k + rank)
        top = sorted(fused.items(), key=lambda t: (-t[1], t[0]))[:k]
        return [Hit(i, s, self.notes[i]["title"], self.notes[i]["body"]) for i, s in top]


def build_retriever(cfg: dict, corpus_path: str, root=None):
    """Build the retriever a config asks for (notes_retrieval.method: bm25 | dense | hybrid)."""
    from pathlib import Path
    root = Path(root or Path(__file__).resolve().parents[1])
    with open(corpus_path) as f:
        notes = [json.loads(line) for line in f if line.strip()]
    r = cfg["notes_retrieval"]
    bm25 = BM25Index(notes)
    if r["method"] == "bm25":
        return bm25
    e = r["embedding_model"]
    dense = DenseIndex(notes, str(root / e["file"]), e.get("query_prefix", ""), e.get("doc_prefix", ""))
    if r["method"] == "dense":
        return dense
    return HybridIndex(bm25, dense, r.get("rrf_k", 60), r.get("bm25_candidates", 10))

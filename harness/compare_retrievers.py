"""Compare notes retrievers on the dev pilot: BM25, dense and hybrid, for each embedding model.

Usage: python harness/compare_retrievers.py
Prints hit@3 and all@3 per slice, file size and Mac query time. Dev pilot only.
"""
import os
import time

from io_utils import read_jsonl
from metrics import retrieval_report
from retrieval import BM25Index, DenseIndex, HybridIndex

CANDIDATES = {
    "bge-small-en-v1.5 q8_0": ("models/embed/bge-small-en-v1.5-q8_0.gguf",
                               "Represent this sentence for searching relevant passages: ", ""),
    "all-MiniLM-L6-v2 Q8_0": ("models/embed/all-MiniLM-L6-v2-Q8_0.gguf", "", ""),
    "nomic-embed-text-v1.5 Q4_K_M": ("models/embed/nomic-embed-text-v1.5.Q4_K_M.gguf",
                                     "search_query: ", "search_document: "),
}
SLICES = ["all", "paraphrase", "lookup", "two_note", "conflict", "number_format", "partial"]


def evaluate(name, index, items, k=3):
    t0 = time.perf_counter()
    got = {it["id"]: [h.note_id for h in index.search(it["question"], k)] for it in items}
    ms = (time.perf_counter() - t0) * 1000 / len(items)
    rep = retrieval_report(items, got, k)
    cells = "  ".join(f"{s}={rep[s][f'hit@{k}']:.2f}/{rep[s][f'all@{k}']:.2f}" for s in SLICES if s in rep)
    print(f"{name:<44} {ms:6.1f} ms/query  {cells}")


def main():
    items, notes = read_jsonl("data/dev/notes_dev.jsonl"), read_jsonl("data/dev/notes_corpus.jsonl")
    bm25 = BM25Index(notes)
    print("hit@3/all@3 per slice (answerable + partial items)\n")
    evaluate("BM25", bm25, items)
    for name, (path, qp, dp) in CANDIDATES.items():
        dense = DenseIndex(notes, path, qp, dp)
        size = os.path.getsize(path) / 1e6
        evaluate(f"dense  {name} ({size:.0f} MB)", dense, items)
        evaluate(f"hybrid {name}", HybridIndex(bm25, dense), items)


if __name__ == "__main__":
    main()

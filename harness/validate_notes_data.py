"""Check the notes dev pilot against its corpus.

Usage: python harness/validate_notes_data.py [--items data/dev/notes_dev.jsonl] [--corpus data/dev/notes_corpus.jsonl]

Checks: unique ids, every cited note exists, answerable/partial items cite at least one note,
unanswerable items cite none, and every key fact appears verbatim (case-insensitive) in a cited
note, except on number_format items, where the reformatting is deliberate.
"""
import argparse
import json
import sys
from collections import Counter


def load(path):
    with open(path) as f:
        return [json.loads(line) for line in f if line.strip()]


def validate(items, corpus):
    errors = []
    notes = {n["id"]: n for n in corpus}
    if len(notes) != len(corpus):
        errors.append("duplicate note ids in corpus")
    ids = [it["id"] for it in items]
    for iid, c in Counter(ids).items():
        if c > 1:
            errors.append(f"{iid}: duplicate item id")
    for it in items:
        g, iid = it["gold"], it["id"]
        for s in g["support"]:
            if s not in notes:
                errors.append(f"{iid}: cites missing note {s}")
        if g["answerable"] is False:
            if g["support"] or g["answer"] != "the notes don't say":
                errors.append(f"{iid}: unanswerable item must cite nothing and answer 'the notes don't say'")
            continue
        if not g["support"]:
            errors.append(f"{iid}: answerable item cites no note")
        if g["answerable"] == "partial" and not g.get("unsupported_part"):
            errors.append(f"{iid}: partial item needs unsupported_part")
        if "number_format" in it["slice"]:
            continue
        text = " ".join(notes[s]["body"].lower() for s in g["support"] if s in notes)
        for fact in g["key_facts"]:
            if fact.lower() not in text:
                errors.append(f"{iid}: key fact {fact!r} not found in cited notes")
    return errors


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--items", default="data/dev/notes_dev.jsonl")
    ap.add_argument("--corpus", default="data/dev/notes_corpus.jsonl")
    a = ap.parse_args()
    items, corpus = load(a.items), load(a.corpus)
    errors = validate(items, corpus)
    slices = Counter(s for it in items for s in it["slice"])
    answerable = Counter(str(it["gold"]["answerable"]) for it in items)
    print(f"{len(items)} items, {len(corpus)} notes")
    print("answerable:", dict(answerable))
    print("slices:", dict(slices))
    for e in errors:
        print("ERROR", e)
    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()

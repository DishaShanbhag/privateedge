# PrivateEdge

**Can a phone-sized model keep up with the cloud?**

PrivateEdge measures how much quality an on-device model loses against a cloud model on two personal-assistant tasks, and tests whether system design (constrained decoding, local retrieval, verification) closes the gap within an iPhone's memory, speed, heat and battery limits.

NYU Generative AI Engineering, Fall 2026. Team: Ananya Singh, Disha Shanbhag, Yash Jain.

## Tasks

1. **Calendar:** turn a message into a calendar event or reminder, or ask for clarification.
2. **Notes:** answer a question over the user's own notes, citing a verbatim quote, or say "the notes don't say".

## Configurations

| Config | Adds |
|---|---|
| B0 | Non-generative baseline (NSDataDetector + rules; BM25 for notes) |
| C0 | Llama 3.2 3B, prompt only (notes: BM25 top-3) |
| C1 | + grammar-constrained decoding |
| C2 | + hybrid local retrieval (notes only; calendar C2 = C1) |
| C3 | + verification |
| C4 | + opt-in escalation to the cloud baseline (stretch) |

Cloud baseline: Gemini 3.8 Flash (`gemini-3.8-flash`). Full design in [`docs/milestone2.pdf`](docs/milestone2.pdf).

## Repository layout

```
ios/            Swift app, llama.cpp runtime, retrieval index
eval/           scoring, paired-bootstrap CI, test-set hashing
configs/        one YAML file per configuration (B0 to C4)
data/dev/       dev pilots (committed, used for all tuning)
data/test/      test set (NOT committed; only its SHA-256 hash is)
data/private/   anonymized real messages and notes (NEVER committed)
results/        per-run outputs and trajectory logs
docs/           milestone reports
conventions.md  date, clarify and scoring rules shared by system and graders
CHANGELOG.md    every change to prompts, schema, conventions or thresholds
```

## Rules for working in this repo

- **Tune only on `data/dev/`.** Nobody who tunes prompts opens the test set.
- **Log every change** to prompts, schema, conventions or thresholds in `CHANGELOG.md` with date, reason and dev-set effect.
- **Freeze on Nov 20:** run `python eval/hash_testset.py data/test/` and commit the hash, then tag the commit `freeze-2026-11-20`. After that, prompts, thresholds and targets do not change.
- **Each configuration sees the test set once.**

## Evaluation scripts

```bash
pip install -r eval/requirements.txt

# Hash the test set (commit the printed hash at freeze time)
python eval/hash_testset.py data/test/

# Score a calendar run against gold labels
python eval/score_calendar.py --gold data/dev/calendar_dev.jsonl --pred results/C0_calendar_dev.jsonl

# Paired-bootstrap 95% CI for the cloud-minus-local gap
python eval/bootstrap_gap.py --local results/C3_scores.csv --cloud results/cloud_scores.csv

# Run tests
python -m pytest eval/tests
```

## Ownership

- **Ananya Singh:** test sets, conventions, rubric, first grader
- **Disha Shanbhag:** calendar dev pilot, evaluation pipeline, verification, ablations, adjudication
- **Yash Jain:** notes dev pilot, iOS app, llama.cpp runtime, retrieval index, device measurements, second grader

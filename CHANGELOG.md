# Changelog

Every change to prompts, schema, conventions or thresholds, with date, reason and dev-set effect. Required by the evaluation design; entries after the freeze are not allowed.

| Date | Config | Change | Reason | Dev-set effect | Author |
|---|---|---|---|---|---|
| 2026-10-29 | all | Repository created; conventions v1 from Milestone 2 | Project setup | n/a | Disha |
| 2026-11-15 | all | Pinned local model: `Llama-3.2-3B-Instruct-Q4_K_M.gguf` from `bartowski/Llama-3.2-3B-Instruct-GGUF`, 2,019,377,696 bytes, SHA-256 `6c1a2b41161032677be168d354123594c0e6e67d2b9227c84f296ad037c728ff` | Every run must use the same weights | n/a | Yash |
| 2026-11-15 | notes data | Added notes dev pilot (`data/dev/notes_dev.jsonl`, 60 items) and corpus (`data/dev/notes_corpus.jsonl`, 49 notes). Gold schema extended: `answerable` may be `"partial"`, plus `key_facts`, `unsupported_part`, `reference_time`. Items drafted with Claude (Anthropic, not the cloud baseline's model family); pending team review | Notes dev pilot | 12 unanswerable (20%); slices: lookup 12, paraphrase 10, number_format 6, two_note 8, conflict 6, partial 6 | Yash |
| 2026-11-15 | B0 | Notes: BM25 top-3 retrieval (same as C0/C1); answer = best-matching sentence of the top note; abstain if top-1 BM25 score < 5.018 (tuned on dev for balanced accuracy) | Resolves B0 top-1 vs top-3 mismatch; a baseline that cannot abstain scores 0 on every unanswerable item | hit@3 0.90 (paraphrase 0.50); abstain recall 0.83, wrongly abstained on 12/48 answerable | Yash |
| 2026-11-15 | C0 | Recorded v0 notes prompt `prompts/notes_v0.txt`; C0 config now names one prompt per task (`prompts.notes`, `prompts.calendar`) | v0 record before any change | Valid JSON 37/60 (18 failures are unquoted `the notes don't say`); strict abstain recall 0/12, wrongly abstained 3 (conflict items) | Yash |
| 2026-11-15 | C1 | Added `schemas/notes.gbnf` (one JSON object, string answer, 0-3 citations); C1 config names one grammar per task (`grammars.notes`, `grammars.calendar`) | Grammar-constrained decoding | Valid JSON 60/60; abstain recall 11/12, wrongly abstained 8 (4 paraphrase retrieval misses, 3 conflicts, 1 number_format); Mac decode median 105 -> 52 tok/s | Yash |

<!-- Template:
| YYYY-MM-DD | C1 | Lowered verifier retrieval threshold 0.62 -> 0.55 | Too many false abstentions on paraphrased notes | Notes score 1.41 -> 1.48, abstention 18% -> 12% | Name |
-->

## Freeze

- Date: _not yet frozen_ (planned 2026-11-20)
- Test-set SHA-256: _see `data/test/TESTSET_SHA256`_
- Git tag: `freeze-2026-11-20`

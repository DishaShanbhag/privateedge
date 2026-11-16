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
| 2026-11-16 | conventions | Task (a) extended from events and reminders to five actions: event, reminder, expense, `none` and clarify. Added an Expenses section (amount as a two-place decimal string, ISO 4217 currency, a bare number means USD, expense dates look backward, no date means the reference date) and a No action section. Added clarify field `amount`. Calendar accuracy is now reported twice: events and reminders only (as proposed) and all actions | Reviewer feedback asked whether the tasks could be expanded; reporting both keeps the proposed number comparable | n/a (before any calendar run) | Disha |
| 2026-11-16 | conventions | Made the date rules precise: a bare weekday is never today; tomorrow/today/tonight; month-day with no year is the next one on or after the reference date; US month/day order; AM/PM cue words, with breakfast/brunch/morning meaning AM and lunch meaning 11:00 to 15:59 (the original rule "meal words mean PM" would put breakfast at 8 in the evening); time ranges; vague dates ask for `date`; fall-back repeated times take the first occurrence | Needed to label the calendar dev pilot unambiguously | n/a (before any calendar run) | Disha |
| 2026-11-16 | scoring | The "no unsupported entity" title rule is now checked in code: every title word that is not a function word must match a message word (small typos and plurals allowed). Scorer also reports schema-valid rate, per-field accuracy and per-slice results | The rule was in conventions.md but the scorer did not check it | n/a (before any calendar run) | Disha |
| 2026-11-16 | calendar data | Calendar dev pilot grown from 4 to 60 items (`data/dev/calendar_dev.jsonl`), original 4 kept as cal-001 to cal-004. Gold now carries source `spans`; clarify items carry `intended`. Added `harness/validate_calendar_data.py`, which recomputes every gold value from the conventions with zoneinfo. Items drafted with Claude (Anthropic, not the cloud baseline's model family); pending team review | Calendar dev pilot | actions: event 20, reminder 8, expense 13, none 6, clarify 13 (22%); slices: dst 5, month_end 8, messy 15, duration 5. Validator found one resolver bug (a span of just "sat" was not read as Saturday), fixed in the resolver | Disha |

<!-- Template:
| YYYY-MM-DD | C1 | Lowered verifier retrieval threshold 0.62 -> 0.55 | Too many false abstentions on paraphrased notes | Notes score 1.41 -> 1.48, abstention 18% -> 12% | Name |
-->

## Freeze

- Date: _not yet frozen_ (planned 2026-11-20)
- Test-set SHA-256: _see `data/test/TESTSET_SHA256`_
- Git tag: `freeze-2026-11-20`

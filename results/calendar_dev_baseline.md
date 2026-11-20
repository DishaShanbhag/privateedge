# Calendar and actions: dev-pilot results (first run 2026-11-16; re-run 2026-11-19 with the date fix)

This is the first full run of the calendar/actions task on the 60-item dev pilot (`data/dev/calendar_dev.jsonl`). Every configuration ran on a Mac with the pinned Llama 3.2 3B Q4_K_M file through llama.cpp, the same model and engine the iPhone app will use. Quality numbers therefore carry over to the phone; latency numbers do not and are Mac-only. The cloud baseline (Gemini 3.8 Flash) has not run yet; see "Cloud baseline" below.

## Results

| Config | All actions | Events and reminders | Schema-valid | Silent errors | Verifier precision / recall | Total time, s (median / p95 / max, Mac) |
|---|---|---|---|---|---|---|
| B0 (rules + NSDataDetector) | 100.0%* | 100.0%* | 60/60 | 0/60 | – | < 0.001 |
| B0, NSDataDetector only | 93.3%* | 89.7%* | 60/60 | 0/60 | – | < 0.001 |
| C0 (prompt only) | 38.3% | 33.3% | 50/60 | 25/60 | – | 1.97 / 4.11 / 5.61 |
| C1 (+ grammar) | 50.0% | 35.9% | 60/60 | 25/60 | – | 2.62 / 4.85 / 5.62 |
| C3 v1 (+ verification, strict spans; before the date fix) | 38.3% | 28.2% | 60/60 | 1/60 | 0.74 / 0.96* | 2.21 / 3.03 / 4.93 |
| **C3 (+ verification)** | **58.3%** | **43.6%** | 60/60 | **1/60** | 0.92 / 0.96* | 2.52 / 4.85 / 5.29 |
| Ablation: C3 + one repair retry | 65.0%* | 51.3%* | 60/60 | 1/60 | 0.92 / 0.96* | 3.21 / 6.87 / 7.77 |
| Ablation: C3 + B0 fallback | 90.0%* | 87.2%* | 60/60 | 1/60 | 0.92 / 0.96* | 2.58 / 4.84 / 6.40 |

\* Optimistic on dev; see "Limitations". "All actions" covers events, reminders, expenses, `none` and clarify items. "Events and reminders" is the task as proposed in Milestone 2 (39 items, including their clarify items). A silent error is an action that is wrong and reaches the user with no clarify question. C2 is identical to C1 for calendar (hybrid retrieval applies to notes only), so it was not run separately.

**Update 2026-11-19.** The model's chat template had written the run machine's date ("Today Date: 16 Nov 2026") into every prompt, contradicting each item's own date. The runner now sets it to the item's reference date (`harness/chat_prompt.py`), and every configuration above was re-run: each gained about 3 points (C3 55.0% -> 58.3%), with the same single silent error. The numbers in the sections below are from the first run; the pattern is unchanged. Mac timings in this re-run are higher than the first run's (other work was running on the Mac) and are Mac-only either way.

## What each step showed

**Format errors are a small part of the gap (C0 to C1).** The grammar made every output schema-valid (49/60 to 60/60). Nearly all of the 11.7-point gain came from the six `none` items, where C0 had added a field the schema does not allow. Real mistakes were unchanged: 26 silent errors, 15 wrong dates or times, and 0 of 5 daylight-saving items correct. The grammar also slowed decoding from 38.6 to 30.7 tokens per second on the Mac.

**Verification removes almost all silent errors (C1 to C3).** The C3 verifier checks the model's values in code: it re-reads the dates, times and amounts from the words the model cited, using the conventions, and checks the title against the message. It caught 25 of the 26 wrong actions and turned them into clarify questions, so silent errors fell from 26 to 1. Only one wrong action reached the user. Verification itself takes well under a millisecond.

**The first verifier asked too often, and was fixed on measured dev failures.** C3 v1 flagged 9 correct outputs, which pulled accuracy down to 38.3%. In 8 of them the value was right but the model labelled its source words badly. For example, when a message had no date, the model copied today's date from the prompt's "Now:" line into its date source. The v2 verifier ignores source words that are not in the message and reads date and time from both sources together, while still requiring an exact match. Precision rose from 0.74 to 0.93 with recall unchanged. This change is logged in `CHANGELOG.md`.

**Recovery options (ablations, not ladder steps).** C3 as proposed recovers by asking. A single repair retry, which sends the failed check back to the model once, raised accuracy to 61.7% at a cost in latency: about 1.5 s per retry, with p95 rising from 2.9 s to 5.2 s. Falling back to B0 reached 88.3%, but that number mostly reflects B0's circular dev score (below).

## Limitations

- **B0's dev score is circular.** The date rules, the 60 dev items and B0's rules were written by the same person from the same reading of the conventions. In addition, the data validator requires every gold label to match those rules. B0 therefore reads every dev item correctly, and its 100% says nothing about real messages. B0's rules are now frozen. Its honest number will come from items written by someone who has not seen the rules: a planned set of blind dev items, and Ananya's test set.
- **C3's precision and recall, the repair retry and the B0 fallback are optimistic for the same reason.** The verifier re-reads dates with the same code that recomputed the gold labels. The repair retry also tells the model what the verifier computed, so the model can copy it.
- **The phone cannot run C3 yet.** The verifier and date rules are Python. Measuring C3 on the iPhone needs a Swift version, or one callable from Swift.
- **Dev items were drafted with Claude** (Anthropic, a different model family from the cloud baseline) and are pending team review.

## Cloud baseline (added 2026-11-19)

Gemini 3.8 Flash (`gemini-3.8-flash`, thinking level low, default temperature) on the same 60 items, prompt and output schema, with billing on: **60/60 = 100.0%** (events and reminders 39/39), all outputs schema-valid, 0 silent errors, total $0.06, cloud latency median 2.4 s and p95 7.0 s. A first run scored 91.7% because Gemini counts its thinking toward the 160-token output cap; the five affected answers were cut off after a few words. Thinking now has its own allowance (CHANGELOG).

| Gap, cloud - local (paired bootstrap, 95% CI) | All actions | Events and reminders |
|---|---|---|
| C1 | 50.0 points [36.7, 61.7] | 64.1 [48.7, 79.5] |
| C3 | 41.7 points [28.3, 53.3] | 56.4 [41.0, 71.8] |

On dev, the local model is far from the cloud and not within the proposal's 5-point margin. Verification narrows the gap by removing almost all silent errors, mostly by asking instead of acting. Two cautions: the dev items were drafted with Claude and are cleaner than real messages, and this is one cloud run on 60 items. The 300-item test set and the real-message items decide the reported gap.

## Reproduce

```bash
source .venv/bin/activate
python harness/validate_calendar_data.py
python harness/b0_calendar.py --out results/B0_calendar_dev
python harness/run_calendar.py --config configs/C3.yaml --out results/C3_calendar_dev     # also C0, C1, C3_repair, C3_fallback_b0
python harness/run_calendar.py --config configs/C1.yaml --backend gemini --out results/cloud_calendar_dev --resume
python eval/score_calendar.py --gold data/dev/calendar_dev.jsonl --pred results/C3_calendar_dev_pred.jsonl \
  --trajectory results/C3_calendar_dev_trajectory.jsonl
python harness/try_calendar.py "dinner with Sam friday at 7"      # try one message
```

# Dev pilots

60 items per task. All tuning happens here. Format: one JSON object per line (`.jsonl`).

## Calendar item (`calendar_dev.jsonl`)

Each item is one message plus the action the system should take. Gold values were typed by hand; `python harness/validate_calendar_data.py` recomputes every one of them from `conventions.md` and fails on any mismatch.

```json
{"id": "cal-001", "message": "dinner Friday at 7?", "reference_time": "2026-11-02T10:00:00-05:00",
 "tz": "America/New_York", "slice": ["resolve"],
 "gold": {"action": "event", "start": "2026-11-06T19:00:00-05:00", "duration_min": 60, "title_terms": ["dinner"],
          "spans": {"date": "Friday", "time": "at 7", "duration": null}}}
```

The five gold shapes:

| `action` | Gold fields |
|---|---|
| `event` | `start` (ISO 8601 with offset), `duration_min`, `title_terms`, `spans` {date, time, duration} |
| `reminder` | `start`, `title_terms`, `spans` {date, time} |
| `expense` | `amount` (string, two decimals), `currency` (ISO 4217), `date` (YYYY-MM-DD), `description_terms`, `spans` {amount, date} |
| `none` | nothing else |
| `clarify` | `fields` (any of them is accepted), `intended` (event, reminder or expense), `spans` |

`spans` are the exact words of the message each gold value comes from (`null` when the message has none and a default applies). Allowed clarify fields: `date`, `start_time`, `ampm`, `which_event`, `conflict`, `invalid_time`, `amount`.

`slice` tags: `resolve`, `reminder`, `clarify`, `expense`, `none`, `duration`, `dst` (around the 14 Mar 2027 change), `month_end` (month and year ends) and `messy` (typos, slang, several sentences).

A calendar predictions file (`results/<config>_calendar_dev_pred.jsonl`) has one line per item, in the shape `harness/calendar_schema.py:to_pred` writes:

```json
{"id": "cal-001", "action": "event", "schema_valid": true, "start": "2026-11-06T19:00:00-05:00", "duration_min": 60, "title": "Dinner"}
{"id": "cal-041", "action": "expense", "schema_valid": true, "amount": "23.50", "currency": "USD", "description": "lunch", "date": "2026-11-01"}
{"id": "cal-003", "action": "clarify", "schema_valid": true, "fields": ["ampm"]}
{"id": "cal-055", "action": null, "schema_valid": false}
```

## Notes corpus (`notes_corpus.jsonl`)

The user's notes that questions are answered from. There's one note per line, and each note is one retrieval chunk.

```json
{"id": "n-001", "title": "Dr. Patel", "body": "Dr. Patel, Tue 3pm. Bring insurance card. Office at 340 E 23rd St, 4th floor.", "created": "2026-10-28"}
```

## Notes item (`notes_dev.jsonl`)

```json
{"id": "note-013", "question": "When is my doctor's appointment?", "reference_time": "2026-11-02T10:00:00-05:00",
 "slice": ["paraphrase"],
 "gold": {"answerable": true, "answer": "Tue 3pm with Dr. Patel", "key_facts": ["Tue 3pm", "Dr. Patel"], "support": ["n-001"]}}
```

- `answerable`: `true`, `false` (gold answer is exactly `the notes don't say`, `support` is empty), or `"partial"` (also has `unsupported_part`, which names the part the notes don't cover; scored 1 at best).
- `key_facts`: facts a correct answer must contain. Graders use them as a checklist. Each one appears verbatim in a cited note, except on `number_format` items, where the reformatting is deliberate.
- `slice`: `lookup`, `paraphrase`, `number_format`, `two_note`, `conflict`, `partial`, `unanswerable` (+ `near_miss` or `off_topic`).
- Check the data with `python harness/validate_notes_data.py`.

A notes predictions file (`results/<config>_notes_dev_pred.jsonl`) has one line per item:
`{"id": "...", "answer": "...", "citations": [{"note_id": "n-001", "quote": "..."}], "abstained": false, "format_ok": true}`.
The matching `_trajectory.jsonl` logs, per item: the retrieved notes and their scores, whether retrieval hit a gold note, whether the cited notes were among those retrieved, whether the quotes are verbatim, the decision (answer or abstain), the raw output, and first-token and total latency.

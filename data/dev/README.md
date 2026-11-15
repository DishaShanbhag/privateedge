# Dev pilots

60 items per task. All tuning happens here. Format: one JSON object per line (`.jsonl`).

## Calendar item (`calendar_dev.jsonl`)

```json
{"id": "cal-001", "message": "dinner Friday at 7?", "reference_time": "2026-11-02T10:00:00-05:00",
 "tz": "America/New_York", "slice": ["resolve"],
 "gold": {"action": "event", "start": "2026-11-06T19:00:00-05:00", "duration_min": 60, "title_terms": ["dinner"]}}
```

A clarify item uses `"gold": {"action": "clarify", "fields": ["ampm"]}`.
Allowed fields: `date`, `start_time`, `ampm`, `which_event`, `conflict`, `invalid_time`.

A predictions file has one line per item: `{"id": "...", "action": "...", "start": "...", "duration_min": 60, "title": "..."}`
or `{"id": "...", "action": "clarify", "fields": ["ampm"]}`.

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

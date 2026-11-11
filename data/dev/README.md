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

## Notes item (`notes_dev.jsonl`)

```json
{"id": "note-001", "question": "When is my doctor's appointment?", "slice": ["paraphrase"],
 "gold": {"answerable": true, "answer": "Tue 3pm with Dr. Patel", "support": ["n-014"]}}
```

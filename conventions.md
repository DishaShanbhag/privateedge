# Conventions

Shared by the system and the graders. Any change goes in `CHANGELOG.md` and is allowed only before the Nov 20 freeze.

## Reference time

- Every item stores a fixed reference timestamp and time zone.
- Default: **Mon 2 Nov 2026, 10:00, America/New_York**.
- About 15% of items are anchored at month or year ends, or across the **14 Mar 2027** DST change.

## Date and time rules

| Phrase | Resolves to |
|---|---|
| "next Thursday" | Thursday of the following Mon to Sun week (from Mon 2 Nov: Thu 12 Nov) |
| bare weekday, e.g. "Friday" | its next occurrence after the reference time (from Mon 2 Nov: Fri 6 Nov) |
| "after 7" | starts at 7:00 |
| meal or evening words ("dinner", "tonight") | PM |
| event with no duration | 60 minutes |
| reminder with no time | 09:00 |

All outputs use ISO 8601 with the zone offset, e.g. `2027-03-15T09:00-04:00`.

## Ask, don't invent

Return `clarify(field)` instead of acting when:

- the date or start time is missing ("coffee sometime");
- AM/PM has no cue ("call at 7");
- two events are possible ("lunch Tue or Wed");
- cues conflict ("Thursday the 6th" when the 6th is a Friday);
- the time does not exist ("Sunday at 2:30am" on 14 Mar 2027, skipped by DST);
- verification fails.

Never add attendees, places or title words absent from the message.

## Notes answers

- Cite the note ID and a verbatim quote for each supporting note.
- Unsupported: answer exactly "the notes don't say".
- Conflicting notes: report both, citing each.

## Scoring

**Calendar** (binary): correct only if action type, date, start time and duration (or reminder time) match exactly, and the title holds every annotated key term and no unsupported entity. A clarify item is correct only if the system asks and names a missing field.

**Notes** (0 to 2):

| Score | Meaning |
|---|---|
| 2 | correct, complete, every claim supported by cited notes; or "the notes don't say" on an unanswerable item |
| 1 | correct but incomplete (e.g. supported part of a partly answerable question) |
| 0 | wrong, any unsupported claim, or any answer to an unanswerable item |

Graded blind to system. 20% double-graded (target Cohen's kappa >= 0.7); a third member adjudicates.

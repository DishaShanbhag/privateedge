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

The rules below make the table precise where real messages need it. They were added on 2026-11-16, before the freeze (see `CHANGELOG.md`).

- **Bare weekdays are never today.** On Monday, "Monday" means the following Monday; "today" is the only way to say today.
- **Relative days.** "Today", "tonight" and "this evening" are the reference date; "tomorrow" (also "tmrw", "tmr") is the next day.
- **A month and day with no year** ("Nov 20", "11/20", always US month/day order) is the next such date on or after the reference date. "The 20th" alone is the next 20th on or after the reference date.
- **AM/PM cues.** Dinner, supper, drinks, tonight, evening, afternoon and night mean PM. Breakfast, brunch and morning mean AM. Lunch means the reading between 11:00 and 15:59, so "lunch at 11:30" is 11:30 and "lunch at 1" is 13:00. A 24-hour time ("19:00") needs no cue. With no cue at all, the system asks (`ampm`).
- **Time ranges.** "2-4pm" starts at 14:00 and lasts 120 minutes; the start takes the end's AM/PM unless that would put it after the end.
- **Vague dates.** "Sometime", "next week" and "this weekend" name no single day, so the system asks (`date`).
- **Repeated times.** If a time occurs twice because clocks fall back, the first occurrence is used.

Added on 2026-11-25 (Ananya's proposed rules, the subset implemented before the freeze; see `CHANGELOG.md`):

- **Weekday phrases.** "This Friday" and "coming Friday" mean a bare weekday. "Friday next week" means "next Friday". "A week from Friday" is the bare-weekday Friday plus 7 days. Two weekdays joined by "or", "and" or "/" ("fri or sat", "sat/sun"), in any case, are two possible events (`which_event`).
- **Offsets.** "Day after tomorrow" is two days after the reference date. "In N days" and "in N weeks" are the reference date plus N or 7N days (N in digits or "a", "one" to "seven"). The time of day comes from the message: an event with none asks `start_time`; a reminder with none is 09:00.
- **Special times.** "Noon" is 12:00. "Around" and "about" before a time, and "ish" after it, give that time. "Half past 6", "quarter past 6" and "quarter to 7" are 6:30, 6:15 and 6:45; the AM/PM cues apply as for any time. A bare hour right after "tonight", "evening" or "night" ("tonight 7") is a PM time.
- **Day-parts with no clock time.** An event asks `start_time`. A reminder with a morning cue is 09:00. A reminder with an afternoon, evening, night or tonight cue asks `start_time`, because 09:00 would contradict the cue.
- **Written dates.** Numeric dates are month/day, separated by "/" or "-" (the same separator throughout), with an optional 2- or 4-digit year (a two-digit year means 20YY); "." works only with a year ("11.20.26"), because "4.75" and "11.20" are prices. A "-" or "." pair that cannot be a month and day ("4-75") is not a date. A number pair followed by am/pm, "ish" or a unit ("2-4pm", "1.5 hours") or preceded by a currency symbol ("$11.20") is not a date. "6 Nov", "6th of Nov" and "Nov. 6th" are accepted. A date that does not exist ("Nov 31", month 13) asks `invalid_time`. "The 31st" in a 30-day month is the next 31st on or after the reference date.

## Expenses

An expense records money the user has already spent. Its fields are `amount`, `currency`, `description` and `date`.

- **Amount** is a decimal with at most two places, written as a string ("23.50"), so no rounding can creep in. "$1,200" is 1200.00 and "$1.2k" is 1200.00.
- **Currency** is an ISO 4217 code. "$", "dollars" and "bucks" are USD; "€" and "euros" are EUR; "£" and "pounds" are GBP; "₹", "Rs" and "rupees" are INR; "C$" and "CA$" are CAD; "A$" and "AU$" are AUD (2026-11-25). A number with no currency word is in the user's home currency, USD for every item in this project. This is a default, like the 60-minute event, not a guess about the message.
- **Date** is a calendar date with no time (`2026-11-01`). Expenses look backward: "yesterday" and "last night" are the day before the reference date; a bare weekday ("Friday") or "last Friday" is its most recent occurrence strictly before the reference date; a month and day with no year ("Oct 28", "10/28") or "the 28th" is the most recent such date on or before the reference date, across a year boundary if needed (this replaces the forward rule above for expenses); "N days ago" is the reference date minus N. A message with no date means the reference date.
- **Description** names what the money was for, using only words from the message.
- The system asks (`amount`) when the amount is missing ("paid for the cab") or two amounts are possible ("$40 or $45").

## No action

Some messages need no action: thanks, small talk, a report of something already done with no money involved, or a question that schedules nothing. The system returns `none` for these. Returning an event or reminder on such a message counts as wrong, and so does asking for clarification.

## Ask, don't invent

Return `clarify(field)` instead of acting when:

- the date or start time is missing ("coffee sometime");
- AM/PM has no cue ("call at 7");
- two events are possible ("lunch Tue or Wed");
- cues conflict ("Thursday the 6th" when the 6th is a Friday);
- the time does not exist ("Sunday at 2:30am" on 14 Mar 2027, skipped by DST);
- verification fails;
- an expense amount is missing or two amounts are possible (`amount`).

Allowed clarify fields: `date`, `start_time`, `ampm`, `which_event`, `conflict`, `invalid_time`, `amount`.

Never add attendees, places or title words absent from the message. In scoring, a title (or expense description) word counts as absent when it is not a common function word ("with", "the", "for", ...) and no word of the message matches it, allowing for small typos and plurals. Date and time words ("Friday", "7pm") never count as invented entities.

## Notes answers

- Cite the note ID and a verbatim quote for each supporting note.
- Unsupported: answer exactly "the notes don't say".
- Conflicting notes: report both, citing each.

## Scoring

**Calendar** (binary): correct only if action type, date, start time and duration (or reminder time) match exactly, and the title holds every annotated key term and no unsupported entity. A clarify item is correct only if the system asks and names a missing field.

An expense is correct only if the amount, currency and date match exactly and the description holds every annotated key term and no unsupported word. A `none` item is correct only if the system returns `none`. Output that fails the schema is wrong.

Calendar accuracy is reported twice. **Events and reminders** (including their clarify items) is the task as proposed in Milestone 2, kept so results stay comparable. **All actions** adds expenses and `none`, the task extension made in response to reviewer feedback. Each has its own gap to the cloud with a paired-bootstrap CI.

**Notes** (0 to 2):

| Score | Meaning |
|---|---|
| 2 | correct, complete, every claim supported by cited notes; or "the notes don't say" on an unanswerable item |
| 1 | correct but incomplete (e.g. supported part of a partly answerable question) |
| 0 | wrong, any unsupported claim, or any answer to an unanswerable item |

Graded blind to system. 20% double-graded (target Cohen's kappa >= 0.7); a third member adjudicates.

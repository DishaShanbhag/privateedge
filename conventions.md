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
- **A month and day with no year** ("Nov 20", "11/20", always US month/day order). For events and reminders it is the next such date on or after the reference date, and "the 20th" alone is the next 20th on or after the reference date. For expenses it is the most recent such date on or before the reference date (see Expenses).
- **AM/PM cues.** Dinner, supper, drinks, tonight, evening, afternoon and night mean PM. Breakfast, brunch and morning mean AM. Lunch means the reading between 11:00 and 15:59, so "lunch at 11:30" is 11:30 and "lunch at 1" is 13:00. A 24-hour time ("19:00") needs no cue. With no cue at all, the system asks (`ampm`).
- **Time ranges.** "2-4pm" starts at 14:00 and lasts 120 minutes; the start takes the end's AM/PM unless that would put it after the end.
- **Vague dates.** "Sometime", "soon", "later", "next week", "this weekend", "next weekend", "end of the week" and "end of the month" name no single day, so the system asks (`date`).
- **Repeated times.** If a time occurs twice because clocks fall back, the first occurrence is used.

The rules below were added on 2026-11-26, while writing the test set (see `CHANGELOG.md`).

- **Weekday phrases.** "This Friday" and "coming Friday" mean a bare weekday. "Friday next week" means "next Friday". Accepted forms, case-insensitive: monday/mon, tuesday/tue/tues, wednesday/wed/weds, thursday/thu/thur/thurs, friday/fri, saturday/sat, sunday/sun. Months: full names and jan, feb, mar, apr, jun, jul, aug, sep, sept, oct, nov, dec, with an optional dot.
- **Offsets.** "Day after tomorrow" is two days after the reference date. "In N days" and "in N weeks" are the reference date plus N days or 7N days. "A week from Friday" is the bare-weekday Friday plus 7 days. The time of day comes from the message, by the usual rules.
- **Times.** "Noon" is 12:00. "ish", "around" and "about" next to a time give that time, and the AM/PM cues still apply ("9ish" with no cue asks `ampm`). "Half past 6", "quarter past 6" and "quarter to 7" are 6:30, 6:15 and 6:45. A number with no "at" and no am/pm is a time only next to a PM cue word ("tonight 7" is 19:00); elsewhere a bare number is not a time ("3 people").
- **Durations and ranges.** "About" or "~" before a duration gives that duration ("~3 hrs" is 180 minutes). Decimal hours are allowed ("2.5 hours" is 150 minutes). "From 2 to 4pm" is the same as "2-4pm".
- **Self-corrections.** When a message corrects itself ("no wait", "sorry", "actually", "I mean"), the last stated value wins, field by field. The source span is the corrected words. If it is unclear which value is corrected, the system asks about that field.
- **Written dates.** Numeric dates are month/day, separated by `/`, `-` or `.`, with an optional 2- or 4-digit year (a 2-digit year is 20YY). "6 Nov", "6th of Nov" and "Nov. 6th" are accepted. A date that does not exist ("Nov 31", "Feb 29 2027", month 13) asks; the gold lists `invalid_time` and `date`, and either is accepted. "The 31st" in a 30-day month is the next 31st.

## Expenses

An expense records money the user has already spent. Its fields are `amount`, `currency`, `description` and `date`.

- **Amount** is a decimal with at most two places, written as a string ("23.50"), so no rounding can creep in. "$1,200" is 1200.00 and "$1.2k" is 1200.00.
- **Currency** is an ISO 4217 code. "$", "dollars" and "bucks" are USD; "€" and "euros" are EUR; "£" and "pounds" are GBP; "₹", "Rs" and "rupees" are INR. A number with no currency word is in the user's home currency, USD for every item in this project. This is a default, like the 60-minute event, not a guess about the message.
- **Date** is a calendar date with no time (`2026-11-01`). Expenses look backward: "yesterday" is the day before the reference date, and a bare weekday ("Friday") is its most recent occurrence strictly before the reference date. A message with no date means the reference date.
- **Month and day with no year.** For expenses, "Oct 28", "10/28" or "the 28th" is the most recent such date on or before the reference date.
- **Relative past.** "Last night" is the day before the reference date. "Last Monday" is the most recent Monday strictly before the reference date, like a bare weekday. "N days ago" is the reference date minus N. "This morning" and "earlier today" are the reference date.
- **Description** names what the money was for, using only words from the message.
- The system asks (`amount`) when the amount is missing ("paid for the cab") or two amounts are possible ("$40 or $45").

## No action

Some messages need no action: thanks, small talk, a report of something already done with no money involved, or a question that schedules nothing. The system returns `none` for these. Returning an event or reminder on such a message counts as wrong, and so does asking for clarification.

## Which action

- A remind-word ("remind me", "reminder", "don't let me forget", "remember to") makes a reminder.
- A dated task, obligation or deadline with no time is a reminder at 09:00. With a time and no remind-word, it is an event.
- A meeting or outing with a date and no time asks `start_time`. A vague invite asks `date`.
- A question that proposes a concrete date or time ("pizza Thursday at 6?") is an event. Questions about the calendar or about other people, chat, thanks, declines and past reports are `none`.

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

- **Key terms.** Gold labels annotate one or two activity words, as they appear in the message, as the title or description key terms. Names and places are optional.
- **Real messages.** None are removed. `reference_time` is when the message was sent, in the sender's zone. Constructs outside the task are tagged `out_of_scope` and labelled as follows: several actions in one message, `clarify(which_event)`; a recurring event or reminder, the first occurrence, ignoring the recurrence word; cancel or reschedule, `none`; a reply that needs earlier context, `clarify(date)`; a zone word that differs from the sender's zone, converted to the sender's zone.
- **Reporting slices.** Items whose answer depends on a rule the prompt does not state are tagged `unstated_rule`. Real items identical to a dev item are tagged `dev_duplicate`. Both are reported separately as well as in the totals.

**Notes** (0 to 2):

| Score | Meaning |
|---|---|
| 2 | correct, complete, every claim supported by cited notes; or "the notes don't say" on an unanswerable item |
| 1 | correct but incomplete (e.g. supported part of a partly answerable question) |
| 0 | wrong, any unsupported claim, or any answer to an unanswerable item |

Graded blind to system. 20% double-graded (target Cohen's kappa >= 0.7); a third member adjudicates.

## Coverage limits

Synthetic test items leave out the constructs below; real items are never filtered. These are reported as limits of the evaluation.

- AM/PM contradicting a cue word ("drinks at 9am").
- Reminders with an afternoon, evening or night cue and no clock time.
- Lunch or brunch times outside their window ("lunch at 9").
- Reminders set in minutes or hours ("in 2 hours"), and "in N months".
- Times already past on the reference date.
- Typos in date and time words. Number words for times or amounts.
- "By" and "before" deadlines.
- Amounts that need arithmetic, per-unit amounts and tips.
- Currencies other than USD, EUR, GBP and INR.
- Recurrence, cancel and reschedule, and several actions in one message.
- Time-zone words.
- Midnight and 12am, and "half 7".
- All-day, overnight and multi-day events, and ranges that cross midnight.
- Feb 29.
- Vague past expense dates ("a couple days ago", "last week").
- "Free" or $0.
- Non-English messages and emoji-only times.

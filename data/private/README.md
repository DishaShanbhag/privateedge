# Private data (never committed)

Anonymized messages and notes from team members (at least 50 items per task). Even anonymized, this is personal data:
keep it local, share it privately, and delete it after the course. Results on these items are reported separately.

## How to add your own messages and notes

1. Copy real messages you are happy to share into a text file, one per line:
   `<time sent, with offset> | <time zone> | <message>`, for example
   `2026-11-03T18:42:00-05:00 | America/New_York | dinner w Sam fri at 7?`
   Notes go in another file: title on the first line, body below, `---` between notes.
2. List the real names of people, places and employers that appear, one per line, in `names.txt`.
3. Run `python harness/intake_real.py messages my_messages.txt --who <initials> --names names.txt`
   (or `notes my_notes.txt`). It refuses to write while it finds phone numbers, emails, URLs, street
   addresses, card or account numbers, or a listed name. Replace each with a placeholder (`<NAME>`,
   `<PHONE>`, `<ADDRESS>`) or a consistent fake, and run it again.
4. Send `data/private/<initials>_messages.jsonl` (and `_notes.jsonl`) to the labeller privately.
   No labels are added by the script; the labeller labels by `conventions.md`. Results on real items
   are reported separately (`real` slice), and nobody who tunes the system sees them before the freeze.

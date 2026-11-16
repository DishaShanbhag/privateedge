"""Deterministic date, time, duration and amount resolution, following conventions.md.

One implementation, used by three callers:
  - validate_calendar_data.py recomputes every gold value from the item's annotated spans;
  - b0_calendar.py (the non-generative baseline) runs it over the whole message;
  - verify_calendar.py (C3) re-resolves the spans the model returned and compares.

Every parse_* function scans a piece of text and returns a result with either a value, a
clarify field (the convention says ask), or neither (nothing found). They never guess.
"""
import re
from dataclasses import dataclass
from datetime import date, datetime, time, timedelta
from decimal import Decimal, InvalidOperation
from typing import Optional
from zoneinfo import ZoneInfo

WEEKDAYS = {
    "monday": 0, "mon": 0, "tuesday": 1, "tue": 1, "tues": 1, "wednesday": 2, "wed": 2, "weds": 2,
    "thursday": 3, "thu": 3, "thur": 3, "thurs": 3, "friday": 4, "fri": 4,
    "saturday": 5, "sat": 5, "sunday": 6, "sun": 6,
}
MONTHS = {
    "january": 1, "jan": 1, "february": 2, "feb": 2, "march": 3, "mar": 3, "april": 4, "apr": 4,
    "may": 5, "june": 6, "jun": 6, "july": 7, "jul": 7, "august": 8, "aug": 8,
    "september": 9, "sep": 9, "sept": 9, "october": 10, "oct": 10, "november": 11, "nov": 11,
    "december": 12, "dec": 12,
}
_WD = "|".join(sorted(WEEKDAYS, key=len, reverse=True))
_MO = "|".join(sorted(MONTHS, key=len, reverse=True))
_ORD = r"(\d{1,2})(?:st|nd|rd|th)?"
_ORDR = r"(\d{1,2})(?:st|nd|rd|th)"  # suffix required

# Words that fix AM/PM (conventions.md, "Date and time rules").
PM_WORDS = re.compile(r"\b(dinner|supper|drinks|tonight|tonite|evening|afternoon|happy hour|night)\b", re.I)
AM_WORDS = re.compile(r"\b(breakfast|brunch|morning)\b", re.I)
LUNCH = re.compile(r"\blunch\b", re.I)
# Phrases that name no single day: the date is missing.
VAGUE_DATE = re.compile(r"\b(sometime|some time|next week|this weekend|next weekend|later this week|soon|one of these days)\b", re.I)


@dataclass
class Parse:
    value: object = None
    clarify: Optional[str] = None
    matched: Optional[str] = None  # the text that produced the value (for spans)


# ---------------------------------------------------------------- dates

def _next_weekday(ref: date, wd: int) -> date:
    """Bare weekday: next occurrence strictly after the reference date (never today)."""
    return ref + timedelta(days=(wd - ref.weekday() - 1) % 7 + 1)


def _prev_weekday(ref: date, wd: int) -> date:
    """Past weekday (expenses): most recent occurrence strictly before the reference date."""
    return ref - timedelta(days=(ref.weekday() - wd - 1) % 7 + 1)


def _next_week_weekday(ref: date, wd: int) -> date:
    """'next Thursday': that weekday in the following Mon-Sun week."""
    monday_next = ref - timedelta(days=ref.weekday()) + timedelta(days=7)
    return monday_next + timedelta(days=wd)


def _month_day(ref: date, month: int, day: int, past: bool) -> Optional[date]:
    """Month and day with no year: next occurrence on or after the reference date
    (expenses: most recent on or before). None if the day does not exist."""
    for year in ([ref.year, ref.year - 1] if past else [ref.year, ref.year + 1]):
        try:
            d = date(year, month, day)
        except ValueError:
            return None
        if (d <= ref) if past else (d >= ref):
            return d
    return None


def _day_of_month(ref: date, day: int, past: bool) -> Optional[date]:
    """'the 20th': this month if on/after the reference date, else next month (past: mirror)."""
    y, m = ref.year, ref.month
    for _ in range(3):
        try:
            d = date(y, m, day)
            if (d <= ref) if past else (d >= ref):
                return d
        except ValueError:
            pass
        y, m = (y, m - 1) if past else (y, m + 1)
        if m == 0:
            y, m = y - 1, 12
        if m == 13:
            y, m = y + 1, 1
    return None


_DATE_PATTERNS = [
    # (name, regex); order matters only for overlapping matches (longest wins anyway)
    ("wd_dom", re.compile(rf"\b(?:this\s+|next\s+)?({_WD})\.?,?\s+(?:the\s+)?{_ORDR}\b", re.I)),
    ("month_day", re.compile(rf"\b({_MO})\.?\s+{_ORD}\b", re.I)),
    ("day_month", re.compile(rf"\b{_ORD}\s+(?:of\s+)?({_MO})\b", re.I)),
    ("numeric", re.compile(r"\b(\d{1,2})/(\d{1,2})(?:/(\d{2,4}))?\b")),
    ("rel", re.compile(r"\b(day after tomorrow|today|tonight|tonite|this (?:morning|afternoon|evening)|"
                       r"tomorrow|tmrw|tmr|tomoz|2morrow|yesterday|last night)\b", re.I)),
    ("next_wd", re.compile(rf"\bnext\s+({_WD})\b\.?", re.I)),
    ("last_wd", re.compile(rf"\blast\s+({_WD})\b\.?", re.I)),
    ("wd", re.compile(rf"\b(?:this\s+|on\s+)?({_WD})\b\.?", re.I)),
    ("dom", re.compile(rf"\b(?:on\s+)?the\s+{_ORDR}\b", re.I)),
]


def _resolve_match(kind, m, ref: date, past: bool):
    """-> (date or None, clarify or None)"""
    g = m.groups()
    if kind == "wd_dom":
        wd, day = WEEKDAYS[g[0].lower()], int(g[1])
        d = _day_of_month(ref, day, past)
        if d is None:
            return None, "invalid_time"
        return (d, None) if d.weekday() == wd else (None, "conflict")
    if kind == "month_day":
        d = _month_day(ref, MONTHS[g[0].lower()], int(g[1]), past)
        return (d, None) if d else (None, "invalid_time")
    if kind == "day_month":
        d = _month_day(ref, MONTHS[g[1].lower()], int(g[0]), past)
        return (d, None) if d else (None, "invalid_time")
    if kind == "numeric":  # US order: month/day
        mo, day = int(g[0]), int(g[1])
        if g[2]:
            y = int(g[2]) + (2000 if len(g[2]) == 2 else 0)
            try:
                return date(y, mo, day), None
            except ValueError:
                return None, "invalid_time"
        if not 1 <= mo <= 12:
            return None, "invalid_time"
        d = _month_day(ref, mo, day, past)
        return (d, None) if d else (None, "invalid_time")
    if kind == "rel":
        w = g[0].lower()
        if w in ("today", "tonight", "tonite") or w.startswith("this "):
            return ref, None
        if w == "day after tomorrow":
            return ref + timedelta(days=2), None
        if w in ("yesterday", "last night"):
            return ref - timedelta(days=1), None
        return ref + timedelta(days=1), None  # tomorrow and its spellings
    if kind == "next_wd":
        return _next_week_weekday(ref, WEEKDAYS[g[0].lower()]), None
    if kind == "last_wd":
        return _prev_weekday(ref, WEEKDAYS[g[0].lower()]), None
    if kind == "wd":
        wd = WEEKDAYS[g[0].lower()]
        return (_prev_weekday(ref, wd) if past else _next_weekday(ref, wd)), None
    if kind == "dom":
        d = _day_of_month(ref, int(g[0]), past)
        return (d, None) if d else (None, "invalid_time")
    raise ValueError(kind)


def _find_dates(text):
    """Non-overlapping date mentions, longest first: [(start, end, kind, match)]."""
    found = []
    for kind, rx in _DATE_PATTERNS:
        for m in rx.finditer(text):
            if kind == "wd" and m.group(1).lower() in ("sat", "sun", "wed", "mar", "may") and not _looks_like_day(text, m):
                continue
            found.append((m.start(), m.end(), kind, m))
    found.sort(key=lambda f: (-(f[1] - f[0]), f[0]))
    chosen = []
    for f in found:
        if all(f[1] <= c[0] or f[0] >= c[1] for c in chosen):
            chosen.append(f)
    return sorted(chosen, key=lambda f: f[0])


def _looks_like_day(text, m):
    # "sun" and "sat" are also ordinary words; accept them only next to a time or "on".
    after = text[m.end():m.end() + 12].lower()
    before = text[max(0, m.start() - 4):m.start()].lower()
    return bool(re.match(r"\s*(at|@|\d|morning|night|afternoon|evening)", after)) or before.strip().endswith("on") \
        or m.group(0)[:1].isupper()


def parse_date(text, ref: date, past=False) -> Parse:
    """Resolve the date mentioned in `text`. Two different dates -> clarify(which_event);
    a vague date ('sometime', 'next week') -> clarify(date); none -> empty Parse."""
    if not text:
        return Parse()
    hits = _find_dates(text)
    results = []
    for s, e, kind, m in hits:
        d, cl = _resolve_match(kind, m, ref, past)
        if cl:
            return Parse(clarify=cl, matched=text[s:e])
        results.append((d, text[s:e]))
    distinct = {d for d, _ in results}
    if len(distinct) > 1:
        return Parse(clarify="which_event", matched=" / ".join(t for _, t in results))
    if results:
        return Parse(value=results[0][0], matched=results[0][1])
    if VAGUE_DATE.search(text):
        return Parse(clarify="date", matched=VAGUE_DATE.search(text).group(0))
    return Parse()


# ---------------------------------------------------------------- times

_TIME = re.compile(
    r"\b(?P<pre>at|@|after|around|by|from|starting|start)?\s*"
    r"(?P<h>\d{1,2})(?::(?P<m>\d{2}))?(?P<ap>\s*[ap]\.?m\b\.?|[ap]\b)?(?P<ish>ish)?"
    r"(?:\s*(?:-|–|to|till|until)\s*(?P<h2>\d{1,2})(?::(?P<m2>\d{2}))?\s*(?P<ap2>\s*[ap]\.?m\b\.?)?)?(?![\d/])",
    re.I)
_NOON = re.compile(r"\b(noon|midday|midnight)\b", re.I)


def _ampm(ap):
    if not ap:
        return None
    return "am" if ap.strip().lower().startswith("a") else "pm"


def _apply(h, ap):
    h = h % 12
    return h + 12 if ap == "pm" else h


def _cue(message, h):
    """AM/PM from words in the whole message, or None. Lunch picks the reading in 11:00-15:59."""
    if PM_WORDS.search(message):
        return "pm"
    if AM_WORDS.search(message):
        return "am"
    if LUNCH.search(message):
        return "am" if h == 11 else "pm"
    return None


def _time_candidates(text):
    out = []
    for m in _TIME.finditer(text):
        h = int(m.group("h"))
        has_marker = m.group("pre") or m.group("m") or m.group("ap") or m.group("h2") or m.group("ish")
        if not has_marker or h > 24:
            continue  # a bare number ("3 people", "$20") is not a time
        # a numeric date ("11/20") or money ("$20") is not a time
        if text[m.end():m.end() + 1] == "/" or text[max(0, m.start() - 1):m.start()] == "/":
            continue
        if text[max(0, m.start() - 1):m.start()] in ("$", "£", "€", "₹"):
            continue
        out.append(m)
    return out


@dataclass
class TimeValue:
    start: time
    duration_min: Optional[int] = None  # from a range like "2-4pm"


def parse_time(text, message) -> Parse:
    """Resolve the start time in `text`; AM/PM cues come from the whole `message`.
    No AM/PM cue -> clarify(ampm). Two different times -> clarify(which_event)."""
    if not text:
        return Parse()
    noon = _NOON.search(text)
    cands = _time_candidates(text)
    vals = []
    for m in cands:
        h, mi = int(m.group("h")), int(m.group("m") or 0)
        if mi > 59:
            continue
        ap, ap2 = _ampm(m.group("ap")), _ampm(m.group("ap2"))
        h2 = int(m.group("h2")) if m.group("h2") else None
        if h2 is not None and ap is None and ap2 is not None:
            # "2-4pm": the start shares the end's half of the day unless that puts it after the end
            ap = ap2
            if _apply(h, ap) > _apply(h2, ap2) and ap2 == "pm":
                ap = "am"
        if ap is None:
            if h == 0 or h >= 13 or (m.group("m") and len(m.group("h")) == 2 and h < 10):
                vals.append((m, time(h % 24, mi), h2, ap2))  # 24-hour clock ("19:00", "07:30")
                continue
            ap = _cue(message, h)
            if ap is None:
                return Parse(clarify="ampm", matched=m.group(0).strip())
        if h > 12:
            continue
        vals.append((m, time(_apply(h, ap), mi), h2, ap2 or ap))
    if noon and not vals:
        return Parse(value=TimeValue(time(0 if noon.group(1).lower() == "midnight" else 12, 0)), matched=noon.group(0))
    if not vals:
        return Parse()
    if len({v[1] for v in vals}) > 1:
        return Parse(clarify="which_event", matched=" / ".join(v[0].group(0).strip() for v in vals))
    m, t, h2, ap2 = vals[0]
    dur = None
    if h2 is not None:
        end = time(_apply(h2, ap2), int(m.group("m2") or 0)) if h2 <= 12 else time(h2 % 24, int(m.group("m2") or 0))
        mins = (end.hour * 60 + end.minute) - (t.hour * 60 + t.minute)
        dur = mins if mins > 0 else None
    return Parse(value=TimeValue(t, dur), matched=m.group(0).strip())


# ---------------------------------------------------------------- durations

_DUR = re.compile(
    r"\b(?:for\s+)?(?:(?P<half>an hour and a half|half an hour|half hour)|"
    r"(?P<n>\d+(?:\.\d+)?|an?|one|two|three)\s*(?P<u>hours?|hrs?|minutes?|mins?)\b)",
    re.I)
_WORDNUM = {"a": 1, "an": 1, "one": 1, "two": 2, "three": 3}


def parse_duration(text) -> Parse:
    if not text:
        return Parse()
    m = _DUR.search(text)
    if not m:
        return Parse()
    if m.group("half"):
        h = m.group("half").lower()
        return Parse(value=90 if "and a half" in h else 30, matched=m.group(0).strip())
    n = m.group("n").lower()
    qty = float(_WORDNUM.get(n, n))
    mins = qty * 60 if m.group("u").lower().startswith("h") else qty
    return Parse(value=int(round(mins)), matched=m.group(0).strip())


# ---------------------------------------------------------------- combining

def combine(d: date, t: time, tz: str) -> Parse:
    """Local date + time in `tz` -> aware datetime. A time skipped by DST -> clarify(invalid_time).
    A repeated time (fall back) takes the first occurrence (fold=0)."""
    z = ZoneInfo(tz)
    dt = datetime.combine(d, t, tzinfo=z)
    back = dt.astimezone(ZoneInfo("UTC")).astimezone(z)
    if back.replace(tzinfo=None) != dt.replace(tzinfo=None):
        return Parse(clarify="invalid_time")
    return Parse(value=back)


def iso(dt: datetime) -> str:
    return dt.isoformat(timespec="seconds")


# ---------------------------------------------------------------- amounts

_CUR_SYM = {"$": "USD", "€": "EUR", "£": "GBP", "₹": "INR"}
_CUR_WORD = {
    "usd": "USD", "dollars": "USD", "dollar": "USD", "bucks": "USD", "buck": "USD",
    "eur": "EUR", "euros": "EUR", "euro": "EUR", "gbp": "GBP", "pounds": "GBP", "quid": "GBP",
    "inr": "INR", "rupees": "INR", "rs": "INR",
}
_NUM = r"(\d{1,3}(?:,\d{3})+|\d+)(?:\.(\d{1,2}))?(k\b)?"
_AMOUNT = re.compile(
    rf"(?P<sym>[$€£₹])\s*{_NUM}|{_NUM}\s*(?P<word>{'|'.join(_CUR_WORD)})\b|(?P<rs>rs\.?)\s*{_NUM}", re.I)


def _to_decimal(whole, frac, k):
    try:
        v = Decimal(whole.replace(",", "") + ("." + frac if frac else ""))
    except InvalidOperation:
        return None
    return (v * 1000 if k else v).quantize(Decimal("0.01"))


def parse_amount(text, default_currency="USD", allow_bare=False) -> Parse:
    """Money in `text` -> (Decimal, currency). Two different amounts -> clarify(amount).
    With allow_bare, a lone number with no currency counts and takes the default currency."""
    if not text:
        return Parse()
    vals = []
    for m in _AMOUNT.finditer(text):
        g = m.groups()
        if m.group("sym"):
            v, cur = _to_decimal(g[1], g[2], g[3]), _CUR_SYM[m.group("sym")]
        elif m.group("word"):
            v, cur = _to_decimal(g[4], g[5], g[6]), _CUR_WORD[m.group("word").lower()]
        else:
            v, cur = _to_decimal(g[9], g[10], g[11]), "INR"
        if v is not None and v > 0:
            vals.append(((v, cur), m.group(0).strip()))
    if not vals and allow_bare:
        for m in re.finditer(rf"(?<![\d/:.]){_NUM}(?![\d/:]|\s*(?:am|pm|st|nd|rd|th|min|hour|hr|people|ppl)\b)", text, re.I):
            v = _to_decimal(m.group(1), m.group(2), m.group(3))
            if v is not None and v > 0:
                vals.append(((v, default_currency), m.group(0).strip()))
    if not vals:
        return Parse()
    if len({v for v, _ in vals}) > 1:
        return Parse(clarify="amount", matched=" / ".join(t for _, t in vals))
    return Parse(value=vals[0][0], matched=vals[0][1])

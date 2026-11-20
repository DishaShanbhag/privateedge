import Foundation

// Port of harness/resolver.py. Same rules, same order, same names where possible; the parity run
// (calcore-parity) compares every function here with the Python on the dev data.

/// A value, a clarify field (the conventions say ask), or neither (nothing found). Never a guess.
public struct Parse<T> {
    public var value: T?
    public var clarify: String?
    public var matched: String?
    public init(value: T? = nil, clarify: String? = nil, matched: String? = nil) {
        self.value = value; self.clarify = clarify; self.matched = matched
    }
}

let WEEKDAYS: [String: Int] = [
    "monday": 0, "mon": 0, "tuesday": 1, "tue": 1, "tues": 1, "wednesday": 2, "wed": 2, "weds": 2,
    "thursday": 3, "thu": 3, "thur": 3, "thurs": 3, "friday": 4, "fri": 4,
    "saturday": 5, "sat": 5, "sunday": 6, "sun": 6,
]
let MONTHS: [String: Int] = [
    "january": 1, "jan": 1, "february": 2, "feb": 2, "march": 3, "mar": 3, "april": 4, "apr": 4,
    "may": 5, "june": 6, "jun": 6, "july": 7, "jul": 7, "august": 8, "aug": 8,
    "september": 9, "sep": 9, "sept": 9, "october": 10, "oct": 10, "november": 11, "nov": 11,
    "december": 12, "dec": 12,
]
private func alt(_ words: [String]) -> String {
    words.sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }.joined(separator: "|")
}
private let WD = alt(Array(WEEKDAYS.keys)), MO = alt(Array(MONTHS.keys))
private let ORD = #"(\d{1,2})(?:st|nd|rd|th)?"#
private let ORDR = #"(\d{1,2})(?:st|nd|rd|th)"#

let PM_WORDS = RX(#"\b(dinner|supper|drinks|tonight|tonite|evening|afternoon|happy hour|night)\b"#, ci: true)
let AM_WORDS = RX(#"\b(breakfast|brunch|morning)\b"#, ci: true)
let LUNCH = RX(#"\blunch\b"#, ci: true)
let VAGUE_DATE = RX(#"\b(sometime|some time|next week|this weekend|next weekend|later this week|soon|one of these days)\b"#, ci: true)

/// Python int() on a run of (possibly non-ASCII) decimal digits.
func pyInt(_ s: String) -> Int {
    s.reduce(0) { $0 * 10 + ($1.wholeNumberValue ?? 0) }
}

private func asciiDigits(_ s: String) -> String {
    String(s.map { c -> Character in
        if let v = c.wholeNumberValue, c.isNumber, !c.isASCII { return Character(String(v)) }
        return c
    })
}

// ---------------------------------------------------------------- dates

/// Bare weekday: next occurrence strictly after the reference date (never today).
func nextWeekday(_ ref: Day, _ wd: Int) -> Day { ref.adding(pmod(wd - ref.weekday - 1, 7) + 1) }
/// Past weekday (expenses): most recent occurrence strictly before the reference date.
func prevWeekday(_ ref: Day, _ wd: Int) -> Day { ref.adding(-(pmod(ref.weekday - wd - 1, 7) + 1)) }
/// "next Thursday": that weekday in the following Mon-Sun week.
func nextWeekWeekday(_ ref: Day, _ wd: Int) -> Day { ref.adding(-ref.weekday + 7 + wd) }

/// Month and day with no year: next occurrence on or after the reference date (past: most recent
/// on or before). nil if the day does not exist.
func monthDay(_ ref: Day, _ month: Int, _ day: Int, past: Bool) -> Day? {
    for year in past ? [ref.y, ref.y - 1] : [ref.y, ref.y + 1] {
        guard let d = Day(year, month, day) else { return nil }
        if past ? d <= ref : d >= ref { return d }
    }
    return nil
}

/// "the 20th": this month if on/after the reference date, else next month (past: mirror).
func dayOfMonth(_ ref: Day, _ day: Int, past: Bool) -> Day? {
    var y = ref.y, m = ref.m
    for _ in 0..<3 {
        if let d = Day(y, m, day), past ? d <= ref : d >= ref { return d }
        if past { m -= 1 } else { m += 1 }
        if m == 0 { y -= 1; m = 12 }
        if m == 13 { y += 1; m = 1 }
    }
    return nil
}

private let DATE_PATTERNS: [(String, RX)] = [
    ("wd_dom", RX(#"\b(?:this\s+|next\s+)?(\#(WD))\.?,?\s+(?:the\s+)?\#(ORDR)\b"#, ci: true)),
    ("month_day", RX(#"\b(\#(MO))\.?\s+\#(ORD)\b"#, ci: true)),
    ("day_month", RX(#"\b\#(ORD)\s+(?:of\s+)?(\#(MO))\b"#, ci: true)),
    ("numeric", RX(#"\b(\d{1,2})/(\d{1,2})(?:/(\d{2,4}))?\b"#)),
    ("rel", RX(#"\b(day after tomorrow|today|tonight|tonite|this (?:morning|afternoon|evening)|tomorrow|tmrw|tmr|tomoz|2morrow|yesterday|last night)\b"#, ci: true)),
    ("next_wd", RX(#"\bnext\s+(\#(WD))\b\.?"#, ci: true)),
    ("last_wd", RX(#"\blast\s+(\#(WD))\b\.?"#, ci: true)),
    ("wd", RX(#"\b(?:this\s+|on\s+)?(\#(WD))\b\.?"#, ci: true)),
    ("dom", RX(#"\b(?:on\s+)?the\s+\#(ORDR)\b"#, ci: true)),
]

private func resolveMatch(_ kind: String, _ m: RM, _ ref: Day, _ past: Bool) -> (Day?, String?) {
    switch kind {
    case "wd_dom":
        let wd = WEEKDAYS[m.g(1)!.pyLower]!
        guard let d = dayOfMonth(ref, pyInt(m.g(2)!), past: past) else { return (nil, "invalid_time") }
        return d.weekday == wd ? (d, nil) : (nil, "conflict")
    case "month_day":
        let d = monthDay(ref, MONTHS[m.g(1)!.pyLower]!, pyInt(m.g(2)!), past: past)
        return d != nil ? (d, nil) : (nil, "invalid_time")
    case "day_month":
        let d = monthDay(ref, MONTHS[m.g(2)!.pyLower]!, pyInt(m.g(1)!), past: past)
        return d != nil ? (d, nil) : (nil, "invalid_time")
    case "numeric":  // US order: month/day
        let mo = pyInt(m.g(1)!), day = pyInt(m.g(2)!)
        if let ys = m.g(3) {
            let y = pyInt(ys) + (ys.count == 2 ? 2000 : 0)
            guard let d = Day(y, mo, day) else { return (nil, "invalid_time") }
            return (d, nil)
        }
        guard (1...12).contains(mo) else { return (nil, "invalid_time") }
        let d = monthDay(ref, mo, day, past: past)
        return d != nil ? (d, nil) : (nil, "invalid_time")
    case "rel":
        let w = m.g(1)!.pyLower
        if ["today", "tonight", "tonite"].contains(w) || w.hasPrefix("this ") { return (ref, nil) }
        if w == "day after tomorrow" { return (ref.adding(2), nil) }
        if w == "yesterday" || w == "last night" { return (ref.adding(-1), nil) }
        return (ref.adding(1), nil)  // tomorrow and its spellings
    case "next_wd":
        return (nextWeekWeekday(ref, WEEKDAYS[m.g(1)!.pyLower]!), nil)
    case "last_wd":
        return (prevWeekday(ref, WEEKDAYS[m.g(1)!.pyLower]!), nil)
    case "wd":
        let wd = WEEKDAYS[m.g(1)!.pyLower]!
        return (past ? prevWeekday(ref, wd) : nextWeekday(ref, wd), nil)
    case "dom":
        let d = dayOfMonth(ref, pyInt(m.g(1)!), past: past)
        return d != nil ? (d, nil) : (nil, "invalid_time")
    default:
        fatalError(kind)
    }
}

private struct Hit { let s: Int, e: Int, kind: String, m: RM, order: Int }

/// Non-overlapping date mentions, longest first.
private func findDates(_ text: String) -> [Hit] {
    var found: [Hit] = []
    for (kind, rx) in DATE_PATTERNS {
        for m in rx.all(text) {
            if kind == "wd", ["sat", "sun", "wed", "mar", "may"].contains(m.g(1)!.pyLower), !looksLikeDay(text, m) {
                continue
            }
            found.append(Hit(s: m.start, e: m.end, kind: kind, m: m, order: found.count))
        }
    }
    found.sort { a, b in  // Python's stable sort on (-length, start)
        if a.e - a.s != b.e - b.s { return a.e - a.s > b.e - b.s }
        if a.s != b.s { return a.s < b.s }
        return a.order < b.order
    }
    var chosen: [Hit] = []
    for f in found where chosen.allSatisfy({ f.e <= $0.s || f.s >= $0.e }) { chosen.append(f) }
    return chosen.sorted { $0.s < $1.s }
}

private let DAY_AFTER = RX(#"^\s*(at|@|\d|morning|night|afternoon|evening)"#)

/// "sun" and "sat" are also ordinary words; accept them only next to a time or "on",
/// capitalised, or when the text is the word alone (an annotated or model-returned span).
private func looksLikeDay(_ text: String, _ m: RM) -> Bool {
    if text.pyStrip(" .,!?").pyLower == m.text.pyStrip(" .").pyLower { return true }
    let after = text.sl(m.end, m.end + 12).pyLower
    let before = text.sl(max(0, m.start - 4), m.start).pyLower
    return DAY_AFTER.first(after) != nil || before.pyStrip().hasSuffix("on") || (m.text.first?.isUppercase ?? false)
}

/// Resolve the date mentioned in `text`. Two different dates -> clarify(which_event); a vague date
/// ("sometime", "next week") -> clarify(date); none -> empty Parse.
public func parseDate(_ text: String?, _ ref: Day, past: Bool = false) -> Parse<Day> {
    guard let text, !text.isEmpty else { return Parse() }
    var results: [(Day, String)] = []
    for h in findDates(text) {
        let (d, cl) = resolveMatch(h.kind, h.m, ref, past)
        if let cl { return Parse(clarify: cl, matched: text.sl(h.s, h.e)) }
        results.append((d!, text.sl(h.s, h.e)))
    }
    if Set(results.map(\.0)).count > 1 {
        return Parse(clarify: "which_event", matched: results.map(\.1).joined(separator: " / "))
    }
    if let r = results.first { return Parse(value: r.0, matched: r.1) }
    if let v = VAGUE_DATE.first(text) { return Parse(clarify: "date", matched: v.text) }
    return Parse()
}

// ---------------------------------------------------------------- times

private let TIME = RX(
    #"\b(?<pre>at|@|after|around|by|from|starting|start)?\s*"#
    + #"(?<h>\d{1,2})(?::(?<m>\d{2}))?(?<ap>\s*[ap]\.?m\b\.?|[ap]\b)?(?<ish>ish)?"#
    + #"(?:\s*(?:-|–|to|till|until)\s*(?<h2>\d{1,2})(?::(?<m2>\d{2}))?\s*(?<ap2>\s*[ap]\.?m\b\.?)?)?(?![\d/])"#,
    ci: true)
private let NOON = RX(#"\b(noon|midday|midnight)\b"#, ci: true)

private func ampm(_ ap: String?) -> String? {
    guard let ap, !ap.isEmpty else { return nil }
    return ap.pyStrip().pyLower.hasPrefix("a") ? "am" : "pm"
}

private func apply(_ h: Int, _ ap: String?) -> Int {
    let x = h % 12
    return ap == "pm" ? x + 12 : x
}

/// AM/PM from words in the whole message, or nil. Lunch picks the reading in 11:00-15:59.
private func cue(_ message: String, _ h: Int) -> String? {
    if PM_WORDS.first(message) != nil { return "pm" }
    if AM_WORDS.first(message) != nil { return "am" }
    if LUNCH.first(message) != nil { return h == 11 ? "am" : "pm" }
    return nil
}

private func nonEmpty(_ s: String?) -> Bool { !(s ?? "").isEmpty }

private func timeCandidates(_ text: String) -> [RM] {
    TIME.all(text).filter { m in
        let h = pyInt(m.g("h")!)
        let marker = nonEmpty(m.g("pre")) || nonEmpty(m.g("m")) || nonEmpty(m.g("ap")) || nonEmpty(m.g("h2")) || nonEmpty(m.g("ish"))
        if !marker || h > 24 { return false }  // a bare number ("3 people", "$20") is not a time
        // a numeric date ("11/20") or money ("$20") is not a time
        if text.sl(m.end, m.end + 1) == "/" || text.sl(max(0, m.start - 1), m.start) == "/" { return false }
        if ["$", "£", "€", "₹"].contains(text.sl(max(0, m.start - 1), m.start)) { return false }
        return true
    }
}

public struct TimeValue: Hashable {
    public let start: HM
    public let durationMin: Int?  // from a range like "2-4pm"
}

/// Resolve the start time in `text`; AM/PM cues come from the whole `message`.
/// No AM/PM cue -> clarify(ampm). Two different times -> clarify(which_event).
public func parseTime(_ text: String?, _ message: String) -> Parse<TimeValue> {
    guard let text, !text.isEmpty else { return Parse() }
    let noon = NOON.first(text)
    var vals: [(RM, HM, Int?, String?)] = []
    for m in timeCandidates(text) {
        let h = pyInt(m.g("h")!), mi = pyInt(m.g("m") ?? "0")
        if mi > 59 { continue }
        var ap = ampm(m.g("ap"))
        let ap2 = ampm(m.g("ap2"))
        let h2 = m.g("h2").map(pyInt)
        if let h2, ap == nil, let ap2 {
            // "2-4pm": the start shares the end's half of the day unless that puts it after the end
            ap = ap2
            if apply(h, ap) > apply(h2, ap2), ap2 == "pm" { ap = "am" }
        }
        if ap == nil {
            if h == 0 || h >= 13 || (nonEmpty(m.g("m")) && m.g("h")!.count == 2 && h < 10) {
                vals.append((m, HM(h: h % 24, m: mi), h2, ap2))  // 24-hour clock ("19:00", "07:30")
                continue
            }
            ap = cue(message, h)
            if ap == nil { return Parse(clarify: "ampm", matched: m.text.pyStrip()) }
        }
        if h > 12 { continue }
        vals.append((m, HM(h: apply(h, ap), m: mi), h2, ap2 ?? ap))
    }
    if let noon, vals.isEmpty {
        let midnight = noon.g(1)!.pyLower == "midnight"
        return Parse(value: TimeValue(start: HM(h: midnight ? 0 : 12, m: 0), durationMin: nil), matched: noon.text)
    }
    guard let (m, t, h2, ap2) = vals.first else { return Parse() }
    if Set(vals.map(\.1)).count > 1 {
        return Parse(clarify: "which_event", matched: vals.map { $0.0.text.pyStrip() }.joined(separator: " / "))
    }
    var dur: Int? = nil
    if let h2 {
        let m2 = pyInt(m.g("m2") ?? "0")
        let endH = h2 <= 12 ? apply(h2, ap2) : h2 % 24
        if m2 <= 59 {  // Python raises on minutes > 59; the parity export records that as an error
            let mins = (endH * 60 + m2) - (t.h * 60 + t.m)
            dur = mins > 0 ? mins : nil
        }
    }
    return Parse(value: TimeValue(start: t, durationMin: dur), matched: m.text.pyStrip())
}

// ---------------------------------------------------------------- durations

private let DUR = RX(
    #"\b(?:for\s+)?(?:(?<half>an hour and a half|half an hour|half hour)|"#
    + #"(?<n>\d+(?:\.\d+)?|an?|one|two|three)\s*(?<u>hours?|hrs?|minutes?|mins?)\b)"#,
    ci: true)
private let WORDNUM: [String: Double] = ["a": 1, "an": 1, "one": 1, "two": 2, "three": 3]

public func parseDuration(_ text: String?) -> Parse<Int> {
    guard let text, !text.isEmpty, let m = DUR.first(text) else { return Parse() }
    if let half = m.g("half") {
        return Parse(value: half.pyLower.contains("and a half") ? 90 : 30, matched: m.text.pyStrip())
    }
    let n = m.g("n")!.pyLower
    let qty = WORDNUM[n] ?? Double(asciiDigits(n))!
    let mins = m.g("u")!.pyLower.hasPrefix("h") ? qty * 60 : qty
    return Parse(value: Int(mins.rounded(.toNearestOrEven)), matched: m.text.pyStrip())  // Python round()
}

// ---------------------------------------------------------------- amounts

/// A money value as an exact two-place decimal string ("23.50") and an ISO 4217 code.
public struct Money: Hashable, Sendable {
    public let amount: String
    public let currency: String
}

private let CUR_SYM: [String: String] = ["$": "USD", "€": "EUR", "£": "GBP", "₹": "INR"]
private let CUR_WORDS: [(String, String)] = [  // order matters: it is the regex alternation order
    ("usd", "USD"), ("dollars", "USD"), ("dollar", "USD"), ("bucks", "USD"), ("buck", "USD"),
    ("eur", "EUR"), ("euros", "EUR"), ("euro", "EUR"), ("gbp", "GBP"), ("pounds", "GBP"), ("quid", "GBP"),
    ("inr", "INR"), ("rupees", "INR"), ("rs", "INR"),
]
private let CUR_WORD = Dictionary(uniqueKeysWithValues: CUR_WORDS)
private let NUM = #"(\d{1,3}(?:,\d{3})+|\d+)(?:\.(\d{1,2}))?(k\b)?"#
// Groups: 1 sym, 2-4 number, 5-7 number, 8 word, 9 rs, 10-12 number (as in Python).
private let AMOUNT = RX(
    #"(?<sym>[\$€£₹])\s*\#(NUM)|\#(NUM)\s*(?<word>\#(CUR_WORDS.map(\.0).joined(separator: "|")))\b|(?<rs>rs\.?)\s*\#(NUM)"#,
    ci: true)
private let BARE = RX(#"(?<![\d/:.])\#(NUM)(?![\d/:]|\s*(?:am|pm|st|nd|rd|th|min|hour|hr|people|ppl)\b)"#, ci: true)

/// Two-place decimal string of whole[.frac][k], exact (Python Decimal(...).quantize(0.01)).
func toDecimal(_ whole: String, _ frac: String?, _ k: String?) -> String {
    var w = asciiDigits(whole.replacingOccurrences(of: ",", with: ""))
    var f = asciiDigits(frac ?? "").padding(toLength: 2, withPad: "0", startingAt: 0)
    if k != nil && !(k!.isEmpty) { w += f + "0"; f = "00" }
    w = String(w.drop { $0 == "0" })
    return (w.isEmpty ? "0" : w) + "." + f
}

private func positive(_ dec: String) -> Bool { dec.contains { $0 != "0" && $0 != "." } }

/// Money in `text`. Two different amounts -> clarify(amount). With allowBare, a lone number with no
/// currency counts and takes the default currency.
public func parseAmount(_ text: String?, defaultCurrency: String = "USD", allowBare: Bool = false) -> Parse<Money> {
    guard let text, !text.isEmpty else { return Parse() }
    var vals: [(Money, String)] = []
    for m in AMOUNT.all(text) {
        let v: String, cur: String
        if let sym = m.g("sym") {
            v = toDecimal(m.g(2)!, m.g(3), m.g(4)); cur = CUR_SYM[sym]!
        } else if let word = m.g("word") {
            v = toDecimal(m.g(5)!, m.g(6), m.g(7)); cur = CUR_WORD[word.pyLower]!
        } else {
            v = toDecimal(m.g(10)!, m.g(11), m.g(12)); cur = "INR"
        }
        if positive(v) { vals.append((Money(amount: v, currency: cur), m.text.pyStrip())) }
    }
    if vals.isEmpty && allowBare {
        for m in BARE.all(text) {
            let v = toDecimal(m.g(1)!, m.g(2), m.g(3))
            if positive(v) { vals.append((Money(amount: v, currency: defaultCurrency), m.text.pyStrip())) }
        }
    }
    guard let first = vals.first else { return Parse() }
    if Set(vals.map(\.0)).count > 1 {
        return Parse(clarify: "amount", matched: vals.map(\.1).joined(separator: " / "))
    }
    return Parse(value: first.0, matched: first.1)
}

// ---------------------------------------------------------------- whole actions

/// What the conventions say the action's values are.
public struct Resolved: Hashable {
    public var start: String? = nil        // event, reminder: ISO 8601 with offset
    public var durationMin: Int? = nil     // event
    public var amount: String? = nil       // expense
    public var currency: String? = nil
    public var date: String? = nil
}

/// Resolve an event, reminder or expense from its source spans, applying every default and clarify
/// rule in conventions.md (resolver.resolve_action).
public func resolveAction(_ kind: String, _ spans: [String: String], _ message: String,
                          _ referenceTime: String, _ tz: String) -> Parse<Resolved> {
    let ref = localRef(referenceTime, tz)
    if kind == "expense" {
        let a = parseAmount(spans["amount"], allowBare: true)
        guard a.clarify == nil, let money = a.value else { return Parse(clarify: "amount") }
        let d = parseDate(spans["date"], ref.day, past: true)
        if let c = d.clarify { return Parse(clarify: c) }
        return Parse(value: Resolved(amount: money.amount, currency: money.currency, date: (d.value ?? ref.day).description))
    }
    precondition(kind == "event" || kind == "reminder", kind)
    let d = parseDate(spans["date"], ref.day)
    if let c = d.clarify { return Parse(clarify: c) }
    guard let day = d.value else { return Parse(clarify: "date") }
    let t = parseTime(spans["time"], message)
    if let c = t.clarify { return Parse(clarify: c) }
    var tv = t.value
    if tv == nil {
        if kind == "event" { return Parse(clarify: "start_time") }
        tv = TimeValue(start: HM(h: 9, m: 0), durationMin: nil)  // reminder with no time
    }
    let c = combine(day, tv!.start, tz)
    if let cl = c.clarify { return Parse(clarify: cl) }
    var out = Resolved(start: c.value!.iso)
    if kind == "event" {
        // Python `a or b or 60`: a duration of 0 counts as missing.
        let said = parseDuration(spans["duration"]).value
        out.durationMin = (said ?? 0) != 0 ? said! : ((tv!.durationMin ?? 0) != 0 ? tv!.durationMin! : 60)
    }
    return Parse(value: out)
}

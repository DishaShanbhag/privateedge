import Foundation

// Port of harness/verify_calendar.py (C3) and the title rule of eval/score_calendar.py.

// ---------------------------------------------------------------- title rule

private let FUNCTION_WORDS: Set<String> = Set("""
a an the and or with w w/ for of on at to in into my me our your his her their from by about re
up out back this that is are be it i we you
""".split(whereSeparator: \.isWhitespace).map(String.init))
private let DATEWORDS = RX(
    #"^(\d+(:\d+)?(am|pm|a|p)?|\d+(st|nd|rd|th)|mon|tue|tues|wed|thu|thur|thurs|fri|sat|sun|"#
    + #"(mon|tues|wednes|thurs|fri|satur|sun)day|today|tonight|tomorrow|morning|afternoon|evening|night|"#
    + #"jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec|"#
    + #"january|february|march|april|june|july|august|september|october|november|december)$"#)
private let WORD = RX(#"[a-z0-9][a-z0-9':/]*"#)

func words(_ text: String?) -> [String] { WORD.all((text ?? "").pyLower).map(\.text) }

/// difflib.SequenceMatcher(None, a, b).ratio() (no junk; autojunk only applies at 200+ chars).
public func similarity(_ a: String, _ b: String) -> Double { seqRatio(a, b) }

func seqRatio(_ a0: String, _ b0: String) -> Double {
    let a = Array(a0.unicodeScalars), b = Array(b0.unicodeScalars)
    let total = a.count + b.count
    if total == 0 { return 1.0 }
    var b2j: [Unicode.Scalar: [Int]] = [:]
    for (j, c) in b.enumerated() { b2j[c, default: []].append(j) }

    func longest(_ alo: Int, _ ahi: Int, _ blo: Int, _ bhi: Int) -> (Int, Int, Int) {
        var bi = alo, bj = blo, size = 0
        var j2len: [Int: Int] = [:]
        for i in alo..<ahi {
            var next: [Int: Int] = [:]
            for j in b2j[a[i]] ?? [] {
                if j < blo { continue }
                if j >= bhi { break }
                let k = (j2len[j - 1] ?? 0) + 1
                next[j] = k
                if k > size { bi = i - k + 1; bj = j - k + 1; size = k }
            }
            j2len = next
        }
        while bi > alo, bj > blo, a[bi - 1] == b[bj - 1] { bi -= 1; bj -= 1; size += 1 }
        while bi + size < ahi, bj + size < bhi, a[bi + size] == b[bj + size] { size += 1 }
        return (bi, bj, size)
    }

    var matches = 0
    var queue = [(0, a.count, 0, b.count)]
    while let (alo, ahi, blo, bhi) = queue.popLast() {
        guard alo < ahi, blo < bhi else { continue }
        let (i, j, k) = longest(alo, ahi, blo, bhi)
        if k > 0 {
            matches += k
            if alo < i && blo < j { queue.append((alo, i, blo, j)) }
            if i + k < ahi && j + k < bhi { queue.append((i + k, ahi, j + k, bhi)) }
        }
    }
    return 2.0 * Double(matches) / Double(total)
}

private func matches(_ word: String, _ msgWords: [String]) -> Bool {
    for m in msgWords {
        if word == m || word.pyRStrip("s") == m.pyRStrip("s") { return true }
        if word.pyLen >= 4 && m.pyLen >= 3 && seqRatio(word, m) >= 0.8 { return true }  // "dinnr" -> "dinner"
    }
    return false
}

/// Title words that are not function, date or time words and match no message word.
public func unsupportedWords(_ title: String?, _ message: String) -> [String] {
    let msg = words(message)
    return words(title).filter { !FUNCTION_WORDS.contains($0) && DATEWORDS.first($0) == nil && !matches($0, msg) }
}

// ---------------------------------------------------------------- NSDataDetector

public struct DateHit { public let start: Int, end: Int, text: String }

/// Apple NSDataDetector date matches (UTF-16 offsets). Used only to FIND date text.
public func detectDates(_ message: String) -> [DateHit] {
    guard let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return [] }
    let ns = message as NSString
    return det.matches(in: message, range: NSRange(location: 0, length: ns.length)).map {
        DateHit(start: $0.range.location, end: $0.range.location + $0.range.length, text: ns.substring(with: $0.range))
    }
}

// ---------------------------------------------------------------- verifier

private let FIELD_FOR = ["date": "date", "time": "start_time", "duration": "start_time", "amount": "amount",
                         "title": "conflict", "description": "conflict", "nsdd": "date"]

public struct Verdict: Equatable {
    public var ok: Bool
    public var failed: [String]
    public var clarifyField: String?
    public var details: [String: String]
    public var replaced: [String] = []   // C3 + code values: fields where code replaced the model's value
}

/// The context the verifier needs about one message.
public struct Item {
    public let id: String
    public let message: String
    public let referenceTime: String
    public let tz: String
    public init(id: String, message: String, referenceTime: String, tz: String) {
        self.id = id; self.message = message; self.referenceTime = referenceTime; self.tz = tz
    }
}

public enum SpanPolicy: String { case strict, dropAndMerge = "drop_and_merge" }

/// C3 checks on one schema-valid action (verify_calendar.check).
public func check(_ item: Item, _ action: Action, crosscheck: Bool = true,
                  spanPolicy: SpanPolicy = .dropAndMerge) -> Verdict {
    let msg = item.message
    let kind = action.kind
    guard ["event", "reminder", "expense"].contains(kind) else {
        return Verdict(ok: true, failed: [], clarifyField: nil, details: [:])
    }
    let spans = action.spans
    var failed: [String] = [], details: [String: String] = [:], field: String? = nil
    func fail(_ name: String, _ fld: String, _ why: String) {
        failed.append(name)
        details[name] = why
        field = field ?? fld
    }
    let origDate = spans["date"]
    let lowMsg = msg.pyLower
    let notVerbatim = spans.filter { !lowMsg.pyContains($0.value.pyLower) }
    var used = spans
    if spanPolicy == .strict {
        for k in notVerbatim.keys.sorted(by: { order(kind, $0) < order(kind, $1) }) {
            fail("span_verbatim", FIELD_FOR[k] ?? "conflict", "\(k)=\(notVerbatim[k]!)")
        }
    } else {
        // A span not in the message is ignored, so the defaults apply; date and time are read from
        // both spans together, so a span filed under the wrong key does not matter.
        if !notVerbatim.isEmpty { details["dropped_spans"] = notVerbatim.keys.sorted().joined(separator: ",") }
        for k in notVerbatim.keys { used[k] = nil }
        if kind == "event" || kind == "reminder" {
            let joined = [used["date"], used["time"]].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
            used["date"] = joined.isEmpty ? nil : joined
            used["time"] = joined.isEmpty ? nil : joined
        }
    }
    let need = ["event": ["date", "time"], "reminder": ["date"], "expense": ["amount"]][kind]!
    for k in need where spanPolicy == .strict && (used[k] ?? "").isEmpty {
        fail("spans_present", FIELD_FOR[k]!, "no \(k) span")
    }

    let r = resolveAction(kind, used, msg, item.referenceTime, item.tz)
    if let c = r.clarify {
        fail("resolve", c, "conventions say clarify(\(c))")
    } else if case .expense(let x) = action {
        let v = r.value!
        if v.amount != x.amount || v.currency != x.currency {
            fail("resolve", "amount", "text says \(v.amount!) \(v.currency!), model says \(x.amount) \(x.currency)")
        }
        if v.date != x.date.description { fail("resolve", "date", "text says \(v.date!), model says \(x.date)") }
    } else {
        let v = r.value!
        let start: ZDT, dur: Int?
        switch action {
        case .event(let e): start = e.start; dur = e.durationMin
        case .reminder(let x): start = x.start; dur = nil
        default: fatalError()
        }
        if !sameTime(v.start, start.iso) { fail("resolve", "start_time", "text says \(v.start!), model says \(start.iso)") }
        if kind == "event", v.durationMin != dur {
            fail("resolve", "start_time", "text says \(v.durationMin!) min, model says \(dur!)")
        }
    }

    let title: String
    switch action {
    case .event(let e): title = e.title
    case .reminder(let x): title = x.title
    case .expense(let x): title = x.description
    default: title = ""
    }
    let bad = unsupportedWords(title, msg)
    if !bad.isEmpty { fail("title", "conflict", "not in message: \(bad)") }

    if crosscheck, kind == "event" || kind == "reminder", let od = origDate, !od.isEmpty, lowMsg.pyContains(od.pyLower) {
        let pos = lowMsg.pyFind(od.pyLower), len = od.u16
        let hits = detectDates(msg)
        if pos >= 0, !hits.contains(where: { $0.start < pos + len && pos < $0.end }) {
            fail("nsdd", "date", "NSDataDetector finds no date at the date span")
        }
    }
    return Verdict(ok: failed.isEmpty, failed: failed, clarifyField: field, details: details)
}

private func order(_ kind: String, _ k: String) -> Int { SPAN_KEYS[kind]?.firstIndex(of: k) ?? 99 }

/// C3 with recovery = clarify (as proposed): a failed check becomes clarify(field).
/// drop_and_merge spans: spans not in the message are ignored; date and time are read together.
func spansUsed(_ action: Action, _ msg: String) -> [String: String] {
    let low = msg.pyLower
    var used = action.spans.filter { low.pyContains($0.value.pyLower) }
    if action.kind == "event" || action.kind == "reminder" {
        let joined = [used["date"], used["time"]].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        used["date"] = joined.isEmpty ? nil : joined
        used["time"] = joined.isEmpty ? nil : joined
        // The kept words name no date (the model copied the prompt's "Now:" line, say): read the
        // date and time from the whole message.
        if !mentionsDate(joined) { used["date"] = msg; used["time"] = msg }
    }
    return used
}

/// C3 + code values (verify_calendar.recompute): keep the model's action, title and spans; compute
/// every date, time, duration and amount from the spans with the conventions code.
public func recompute(_ item: Item, _ action: Action, crosscheck: Bool = true) -> (Action, Verdict) {
    var v = Verdict(ok: true, failed: [], clarifyField: nil, details: [:])
    let kind = action.kind
    guard ["event", "reminder", "expense"].contains(kind) else { return (action, v) }
    let msg = item.message
    func ask(_ name: String, _ fld: String, _ why: String) {
        v.ok = false; v.failed.append(name); v.details[name] = why; v.clarifyField = v.clarifyField ?? fld
    }
    let r = resolveAction(kind, spansUsed(action, msg), msg, item.referenceTime, item.tz)
    let title: String
    switch action {
    case .event(let e): title = e.title
    case .reminder(let x): title = x.title
    case .expense(let x): title = x.description
    default: title = ""
    }
    let bad = unsupportedWords(title, msg)
    if !bad.isEmpty { ask("title", "conflict", "not in message: \(bad)") }
    if let c = r.clarify { ask("resolve", c, "conventions say clarify(\(c))") }
    if crosscheck, kind == "event" || kind == "reminder" {
        let nd = check(item, action, crosscheck: true, spanPolicy: .dropAndMerge)
        if nd.failed.contains("nsdd") { ask("nsdd", "date", nd.details["nsdd"] ?? "") }
    }
    if !v.ok { return (.clarify([v.clarifyField!]), v) }
    let val = r.value!
    switch action {
    case .expense(var x):
        if val.amount != x.amount || val.currency != x.currency { v.replaced.append("amount") }
        if val.date != x.date.description { v.replaced.append("date") }
        x.amount = val.amount!; x.currency = val.currency!; x.date = Day.parse(val.date!)!
        return (.expense(x), v)
    case .event(var e):
        if !sameTime(val.start, e.start.iso) { v.replaced.append("start") }
        if val.durationMin != e.durationMin { v.replaced.append("duration") }
        e.start = ZDT.parse(val.start!)!; e.durationMin = val.durationMin!
        return (.event(e), v)
    case .reminder(var x):
        if !sameTime(val.start, x.start.iso) { v.replaced.append("start") }
        x.start = ZDT.parse(val.start!)!
        return (.reminder(x), v)
    default:
        return (action, v)
    }
}

public func verify(_ item: Item, _ action: Action, crosscheck: Bool = true,
                   spanPolicy: SpanPolicy = .dropAndMerge) -> (Action, Verdict) {
    let v = check(item, action, crosscheck: crosscheck, spanPolicy: spanPolicy)
    return v.ok ? (action, v) : (.clarify([v.clarifyField!]), v)
}

// ---------------------------------------------------------------- prompt

private let EN = Locale(identifier: "en_US_POSIX")

/// The user turn (run_calendar.user_message): "Now: Monday, 2 November 2026, 10:00
/// (America/New_York, UTC-05:00).\n\nMessage: ..."
public func userMessage(_ item: Item) -> String {
    let now = localRef(item.referenceTime, item.tz)
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    let date = Date(timeIntervalSince1970: TimeInterval(now.day.ordinal * 86400))
    let f = DateFormatter()
    f.locale = EN; f.calendar = cal; f.timeZone = cal.timeZone
    f.dateFormat = "EEEE"
    let wd = f.string(from: date)
    f.dateFormat = "MMMM"
    let month = f.string(from: date)
    let sign = now.offset < 0 ? "-" : "+", a = abs(now.offset)
    let off = String(format: "%@%02d:%02d", sign, a / 3600, (a % 3600) / 60)
    return String(format: "Now: %@, %d %@ %04d, %02d:%02d (%@, UTC%@).\n\nMessage: %@",
                  wd, now.day.d, month, now.day.y, now.h, now.mi, item.tz, off, item.message)
}

import Foundation

// Port of harness/calendar_schema.py: the five actions, validated with the same rules as the
// Pydantic models, including Pydantic's lax coercions (measured, see the parity fixtures).

public let CLARIFY_FIELDS = ["date", "start_time", "ampm", "which_event", "conflict", "invalid_time", "amount"]
let SPAN_KEYS: [String: [String]] = [
    "event": ["date", "time", "duration", "title"],
    "reminder": ["date", "time", "title"],
    "expense": ["amount", "date", "description"],
]

public struct Event: Equatable { public var title: String; public var start: ZDT; public var durationMin: Int; public var spans: [String: String] }
public struct Reminder: Equatable { public var title: String; public var start: ZDT; public var spans: [String: String] }
public struct Expense: Equatable {
    public var amount: String  // exact two-place decimal, e.g. "23.50"
    public var currency: String
    public var description: String
    public var date: Day
    public var spans: [String: String]
}

public enum Action: Equatable {
    case event(Event)
    case reminder(Reminder)
    case expense(Expense)
    case none
    case clarify([String])

    public var kind: String {
        switch self {
        case .event: return "event"
        case .reminder: return "reminder"
        case .expense: return "expense"
        case .none: return "none"
        case .clarify: return "clarify"
        }
    }
    public var spans: [String: String] {
        switch self {
        case .event(let e): return e.spans
        case .reminder(let r): return r.spans
        case .expense(let x): return x.spans
        default: return [:]
        }
    }
}

struct SchemaError: Error { let msg: String }
private func fail(_ m: String) -> SchemaError { SchemaError(msg: "schema: " + m) }

/// Pydantic's str_strip_whitespace (Rust trim: Unicode White_Space).
private func trim(_ s: String) -> String {
    var sc = Array(s.unicodeScalars)[...]
    while let f = sc.first, f.properties.isWhitespace { sc = sc.dropFirst() }
    while let l = sc.last, l.properties.isWhitespace { sc = sc.dropLast() }
    return String(String.UnicodeScalarView(Array(sc)))
}

private func text(_ v: JV?, _ loc: String) throws -> String {
    guard let s = v?.asString else { throw fail("\(loc): Input should be a valid string") }
    let t = trim(s)
    guard (1...120).contains(t.pyLen) else { throw fail("\(loc): length") }
    return t
}

/// Pydantic lax int: int, bool, a float with no fraction, or a string like " +0_60 " / "60.0".
private func laxInt(_ v: JV?, _ loc: String) throws -> Int {
    switch v {
    case .int(let n)?: return n
    case .bool(let b)?: return b ? 1 : 0
    case .float(let d)?:
        guard d.isFinite, d == d.rounded(), abs(d) < 9e15 else { throw fail("\(loc): integer") }
        return Int(d)
    case .str(let s)?:
        let t = trim(s)
        guard let m = RX(#"^([+-]?)(\d+(?:_\d+)*)(?:\.0*)?$"#).first(t),
              let n = Int(m.g(2)!.replacingOccurrences(of: "_", with: "")) else { throw fail("\(loc): integer") }
        return m.g(1) == "-" ? -n : n
    default: throw fail("\(loc): integer")
    }
}

/// Python str(float) for the shapes JSON produces (shortest repr, "1e-05" / "1e+16" exponents).
func pyFloatStr(_ d: Double) -> String {
    if d == d.rounded(), abs(d) < 1e16 { return String(format: "%.1f", d) }
    let r = "\(d)"  // Swift also prints the shortest round-trip digits
    guard let e = r.firstIndex(of: "e") else { return r }
    var mant = String(r[..<e]), exp = String(r[r.index(after: e)...])
    if mant.hasSuffix(".0") { mant.removeLast(2) }
    let neg = exp.hasPrefix("-")
    exp = exp.trimmingCharacters(in: CharacterSet(charactersIn: "+-"))
    return mant + "e" + (neg ? "-" : "+") + (exp.count < 2 ? "0" + exp : exp)
}

/// Pydantic Decimal with gt=0, lt=1000000, decimal_places=2 -> exact "123.45".
private func amount(_ v: JV?) throws -> String {
    let raw: String
    switch v {
    case .str(let s)?: raw = s
    case .int(let n)?: raw = String(n)
    case .float(let d)?: raw = d.isFinite ? pyFloatStr(d) : "NaN"  // the model's str() pre-step
    default: throw fail("expense.amount: Decimal input should be an integer, float, string or Decimal object")
    }
    let t = trim(raw).replacingOccurrences(of: "_", with: "")
    guard let m = RX(#"^([+-]?)(?:(\d+)(?:\.(\d*))?|\.(\d+))(?:[eE]([+-]?\d+))?$"#).first(t) else {
        throw fail("expense.amount: Input should be a valid decimal")
    }
    let intPart = m.g(2) ?? "", fracPart = m.g(3) ?? m.g(4) ?? ""
    guard let e0 = Int(m.g(5) ?? "0"), abs(e0) < 1000 else { throw fail("expense.amount: out of range") }
    var digits = String((intPart + fracPart).drop { $0 == "0" })
    var exp = e0 - fracPart.count
    if digits.isEmpty { throw fail("expense.amount: Input should be greater than 0") }
    if m.g(1) == "-" { throw fail("expense.amount: Input should be greater than 0") }
    while digits.hasSuffix("0") { digits.removeLast(); exp += 1 }  // normalize, then count places
    if exp < -2 { throw fail("expense.amount: Decimal input should have no more than 2 decimal places") }
    if digits.count + exp > 6 { throw fail("expense.amount: Input should be less than 1000000") }
    var whole: String, frac: String
    if exp >= 0 {
        whole = digits + String(repeating: "0", count: exp); frac = "00"
    } else {
        let padded = String(repeating: "0", count: max(0, -exp - digits.count)) + digits
        whole = String(padded.dropLast(-exp)); frac = String(padded.suffix(-exp))
        frac = frac.padding(toLength: 2, withPad: "0", startingAt: 0)
    }
    if whole.isEmpty { whole = "0" }
    return whole + "." + frac
}

private let TIMESTAMP = RX(#"^[+-]?\d+(?:\.\d+)?$"#)

/// Pydantic's datetime from a unix timestamp (seconds; milliseconds above 2e10).
private func fromTimestamp(_ v: JV?) -> ZDT? {
    let x: Double
    switch v {
    case .int(let n)?: x = Double(n)
    case .float(let d)?: x = d
    case .str(let s)?: guard TIMESTAMP.first(s) != nil, let d = Double(s) else { return nil }; x = d
    default: return nil
    }
    let secs = abs(x) > 2e10 ? x / 1000 : x
    guard secs.isFinite, abs(secs) < 2.5e11 else { return nil }
    let whole = Int(secs.rounded(.down))
    let micro = Int(((secs - Double(whole)) * 1e6).rounded())
    let z = ZDT.at(epoch: whole, in: TimeZone(identifier: "UTC")!)
    return ZDT(day: z.day, h: z.h, mi: z.mi, s: z.s, micro: micro, offset: 0)
}

/// Pydantic AwareDatetime.
private func awareDatetime(_ v: JV?, _ loc: String) throws -> ZDT {
    if let s = v?.asString, let z = ZDT.parse(s) { return z }
    if let z = fromTimestamp(v) { return z }
    throw fail("\(loc): Input should be a valid datetime with timezone info")
}

/// Pydantic date: YYYY-MM-DD, or a datetime / timestamp with zero time.
private func pyDate(_ v: JV?) throws -> Day {
    if let s = v?.asString {
        if let d = Day.parse(s) { return d }
        let naive = RX(#"^(\d{4}-\d{2}-\d{2})[Tt_ ]00:00(?::00(?:[.,]0{1,6})?)?(?:[Zz]|[+-]\d{2}:?\d{2})?$"#)
        if let m = naive.first(s), let d = Day.parse(m.g(1)!) { return d }
    }
    if let z = fromTimestamp(v), z.h == 0, z.mi == 0, z.s == 0, z.micro == 0 { return z.day }
    throw fail("expense.date: Input should be a valid date")
}

private func spans(_ v: JV?, _ kind: String) throws -> [String: String] {
    guard let v else { return [:] }
    guard case .obj(let o) = v else { throw fail("\(kind).spans: Input should be a valid dictionary") }
    var out: [String: String] = [:]
    for k in o.keys {
        guard SPAN_KEYS[kind]!.contains(k) else { throw fail("\(kind).spans.\(k): Extra inputs are not permitted") }
        switch o[k]! {
        case .null: continue
        case .str(let s):
            let t = trim(s)
            guard t.pyLen <= 120 else { throw fail("\(kind).spans.\(k): too long") }
            out[k] = t
        default: throw fail("\(kind).spans.\(k): Input should be a valid string")
        }
    }
    return out
}

private func onlyKeys(_ o: JObj, _ allowed: [String], _ kind: String) throws {
    for k in o.keys where !allowed.contains(k) { throw fail("\(kind).\(k): Extra inputs are not permitted") }
}

/// dict -> Action or a short error (calendar_schema.validate_action).
public func validateAction(_ v: JV) -> (Action?, String?) {
    do { return (try validate(v), nil) } catch let e as SchemaError { return (nil, e.msg) } catch { return (nil, "schema: \(error)") }
}

private func validate(_ v: JV) throws -> Action {
    guard case .obj(let o) = v else { throw fail("Input should be a valid dictionary") }
    guard let tag = o["action"]?.asString, ["event", "reminder", "expense", "none", "clarify"].contains(tag) else {
        throw fail("Input tag found using 'action' does not match any of the expected tags")
    }
    switch tag {
    case "event":
        try onlyKeys(o, ["action", "title", "start", "duration_min", "spans"], tag)
        let title = try text(o["title"], "event.title")
        let start = try awareDatetime(o["start"], "event.start")
        let dur = try laxInt(o["duration_min"], "event.duration_min")
        guard dur > 0 else { throw fail("event.duration_min: Input should be greater than 0") }
        guard dur <= 1440 else { throw fail("event.duration_min: Input should be less than or equal to 1440") }
        return .event(Event(title: title, start: start, durationMin: dur, spans: try spans(o["spans"], tag)))
    case "reminder":
        try onlyKeys(o, ["action", "title", "start", "spans"], tag)
        let title = try text(o["title"], "reminder.title")
        let start = try awareDatetime(o["start"], "reminder.start")
        return .reminder(Reminder(title: title, start: start, spans: try spans(o["spans"], tag)))
    case "expense":
        try onlyKeys(o, ["action", "amount", "currency", "description", "date", "spans"], tag)
        let amt = try amount(o["amount"])
        guard let c = o["currency"]?.asString else { throw fail("expense.currency: Input should be a valid string") }
        let cur = trim(c)
        guard RX(#"^[A-Z]{3}$"#).first(cur) != nil else { throw fail("expense.currency: String should match pattern '^[A-Z]{3}$'") }
        let desc = try text(o["description"], "expense.description")
        let date = try pyDate(o["date"])
        return .expense(Expense(amount: amt, currency: cur, description: desc, date: date, spans: try spans(o["spans"], tag)))
    case "none":
        try onlyKeys(o, ["action"], tag)
        return .none
    default:
        try onlyKeys(o, ["action", "fields"], tag)
        guard case .arr(let a)? = o["fields"] else { throw fail("clarify.fields: Input should be a valid list") }
        var seen: [String] = []
        for x in a {  // repeats dropped first (the "before" validator), then each must be allowed
            guard let s = x.asString else { throw fail("clarify.fields: Input should be a string") }
            if !seen.contains(s) { seen.append(s) }
        }
        guard (1...3).contains(seen.count) else { throw fail("clarify.fields: List should have 1 to 3 items") }
        guard seen.allSatisfy(CLARIFY_FIELDS.contains) else { throw fail("clarify.fields: Input should be one of the clarify fields") }
        return .clarify(seen)
    }
}

/// The first {...} block in the text (code fences allowed), or nil (calendar_schema.extract_json).
public func extractJSON(_ raw: String) -> JObj? {
    var s = raw.pyStrip()
    s = RX(#"^```(?:json)?\s*"#).re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: s.u16), withTemplate: "")
    s = RX(#"\s*```$"#).re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: s.u16), withTemplate: "")
    let a = s.pyFind("{"), b = (s as NSString).range(of: "}", options: [.literal, .backwards]).location
    guard a >= 0, b != NSNotFound, b >= a, case .obj(let o)? = try? parseJSON(s.sl(a, b + 1)) else { return nil }
    return o
}

/// Raw model text -> Action or an error. Never throws (calendar_schema.parse_action).
public func parseAction(_ raw: String) -> (Action?, String?) {
    guard let o = extractJSON(raw) else { return (nil, "not_json") }
    return validateAction(.obj(o))
}

/// The predictions-file row the scorer reads (calendar_schema.to_pred).
public func toPred(_ id: String, _ action: Action?) -> JObj {
    var r = JObj([("id", .str(id))])
    guard let action else {
        r["action"] = .null; r["schema_valid"] = .bool(false)
        return r
    }
    r["action"] = .str(action.kind); r["schema_valid"] = .bool(true)
    switch action {
    case .event(let e):
        r["start"] = .str(e.start.iso); r["title"] = .str(e.title); r["duration_min"] = .int(e.durationMin)
    case .reminder(let x):
        r["start"] = .str(x.start.iso); r["title"] = .str(x.title)
    case .expense(let x):
        r["amount"] = .str(x.amount); r["currency"] = .str(x.currency)
        r["description"] = .str(x.description); r["date"] = .str(x.date.description)
    case .clarify(let f): r["fields"] = .arr(f.map { .str($0) })
    case .none: break
    }
    return r
}

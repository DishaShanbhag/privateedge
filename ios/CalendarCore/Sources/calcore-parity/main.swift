// Compares CalendarCore with the Python on every row of Fixtures/parity.jsonl
// (made by harness/export_swift_parity.py). Exit code 1 if anything differs.
//   swift run calcore-parity [path/to/parity.jsonl]
import CalendarCore
import Foundation

let path = CommandLine.arguments.dropFirst().first
    ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Fixtures/parity.jsonl").standardized.path
guard let data = FileManager.default.contents(atPath: path), let text = String(data: data, encoding: .utf8) else {
    print("cannot read \(path)"); exit(2)
}

let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../..").standardized
let systemPrompt = (try? String(contentsOf: repo.appendingPathComponent("prompts/calendar_v0.txt"), encoding: .utf8)) ?? ""

func s(_ o: JObj, _ k: String) -> String? { o[k]?.asString }
func outObj(_ value: JV, _ clarify: String?, _ matched: String?) -> JV {
    .obj(JObj([("value", value), ("clarify", clarify.map { .str($0) } ?? .null), ("matched", matched.map { .str($0) } ?? .null)]))
}
func item(_ o: JObj) -> Item {
    guard case .obj(let i)? = o["item"] else { fatalError("no item") }
    return Item(id: s(i, "id")!, message: s(i, "message")!, referenceTime: s(i, "reference_time")!, tz: s(i, "tz")!)
}
func spansOf(_ v: JV?) -> [String: String] {
    guard case .obj(let o)? = v else { return [:] }
    var d: [String: String] = [:]
    for k in o.keys { if let x = o[k]?.asString { d[k] = x } }
    return d
}
/// Compare JSON values, with floats equal to 1e-12 and an int equal to the same float.
func same(_ a: JV, _ b: JV) -> Bool {
    switch (a, b) {
    case (.float(let x), .float(let y)): return abs(x - y) < 1e-12
    case (.obj(let x), .obj(let y)):
        return Set(x.keys) == Set(y.keys) && x.keys.allSatisfy { same(x[$0]!, y[$0]!) }
    case (.arr(let x), .arr(let y)): return x.count == y.count && zip(x, y).allSatisfy { same($0, $1) }
    default: return a == b
    }
}

var counts: [String: (Int, Int)] = [:]
var shown: [String: Int] = [:]
for line in text.split(separator: "\n") {
    guard case .obj(let r) = try parseJSON(String(line)) else { continue }
    let t = s(r, "t")!, want = r["out"]!
    if case .obj(let w) = want, w["error"] != nil { continue }  // Python raised; nothing to compare
    var got: JV = .null
    switch t {
    case "user_message":
        got = .str(userMessage(item(r)))
    case "chat_prompt":
        got = .str(chatPrompt(system: systemPrompt, user: userMessage(item(r)), today: s(r, "today")!))
    case "resolve":
        let it = item(r)
        let p = resolveAction(s(r, "kind")!, spansOf(r["spans"]), it.message, it.referenceTime, it.tz)
        var v = JObj()
        if let x = p.value {
            if let st = x.start { v["start"] = .str(st) }
            if let d = x.durationMin { v["duration_min"] = .int(d) }
            if let a = x.amount { v["amount"] = .str(a); v["currency"] = .str(x.currency!); v["date"] = .str(x.date!) }
        }
        got = outObj(p.value == nil ? .null : .obj(v), p.clarify, nil)
    case "date":
        guard let ref = Day.parse(s(r, "ref")!), case .bool(let past)? = r["past"] else { continue }
        let p = parseDate(s(r, "text"), ref, past: past)
        got = outObj(p.value.map { .str($0.description) } ?? .null, p.clarify, p.matched)
    case "time":
        let p = parseTime(s(r, "text"), s(r, "message")!)
        let v: JV = p.value.map {
            .obj(JObj([("start", .str(String(format: "%02d:%02d", $0.start.h, $0.start.m))),
                       ("dur", $0.durationMin.map { .int($0) } ?? .null)]))
        } ?? .null
        got = outObj(v, p.clarify, p.matched)
    case "duration":
        let p = parseDuration(s(r, "text"))
        got = outObj(p.value.map { .int($0) } ?? .null, p.clarify, p.matched)
    case "amount":
        guard case .bool(let bare)? = r["allow_bare"] else { continue }
        let p = parseAmount(s(r, "text"), allowBare: bare)
        got = outObj(p.value.map { .arr([.str($0.amount), .str($0.currency)]) } ?? .null, p.clarify, p.matched)
    case "title":
        got = .arr(unsupportedWords(s(r, "title"), s(r, "message")!).map { .str($0) })
    case "combine":
        let hm = s(r, "hm")!.split(separator: ":").map { Int($0)! }
        let c = combine(Day.parse(s(r, "day")!)!, HM(h: hm[0], m: hm[1]), s(r, "tz")!)
        got = .obj(JObj([("value", c.value.map { .str($0.iso) } ?? .null), ("clarify", c.clarify.map { .str($0) } ?? .null)]))
    case "ratio":
        got = .float(similarity(s(r, "a")!, s(r, "b")!))
    case "parse":
        let (a, _) = parseAction(s(r, "raw")!)
        guard case .obj(let w) = want, let id = w["id"]?.asString else { continue }
        got = .obj(toPred(id, a))
    case "check":
        let it = item(r)
        guard let a = parseAction(s(r, "raw")!).0, case .bool(let cross)? = r["crosscheck"] else {
            got = .str("schema-invalid in Swift"); break
        }
        let v = check(it, a, crosscheck: cross, spanPolicy: SpanPolicy(rawValue: s(r, "policy")!)!)
        got = .obj(JObj([("ok", .bool(v.ok)), ("failed", .arr(v.failed.map { .str($0) })),
                         ("clarify_field", v.clarifyField.map { .str($0) } ?? .null)]))
    default:
        continue
    }
    var expected = want
    if t == "resolve", case .obj(var w) = want { w["matched"] = .null; expected = .obj(w) }
    let ok = same(got, expected)
    counts[t, default: (0, 0)].0 += ok ? 1 : 0
    counts[t, default: (0, 0)].1 += 1
    if !ok, shown[t, default: 0] < 8 {
        shown[t, default: 0] += 1
        print("DIFF [\(t)] \(line.prefix(220))\n   swift:  \(dumpJSON(got))\n   python: \(dumpJSON(expected))")
    }
}
var bad = 0
for (t, (ok, n)) in counts.sorted(by: { $0.key < $1.key }) {
    print(String(format: "%-13@ %5d / %5d agree", t as NSString, ok, n))
    bad += n - ok
}
print(bad == 0 ? "PARITY OK" : "PARITY FAILED: \(bad) differences")
exit(bad == 0 ? 0 : 1)

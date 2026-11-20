import CalendarCore
import Foundation

/// The calendar ladder on the phone. C2 is identical to C1 for calendar (retrieval is notes-only).
enum LadderConfig: String, CaseIterable, Identifiable {
    case C0, C1, C3, C3_repair
    var id: String { rawValue }
    var grammar: Bool { self != .C0 }
    var verify: Bool { self == .C3 || self == .C3_repair }
    var label: String {
        switch self {
        case .C0: return "C0 · prompt only"
        case .C1: return "C1 · + grammar"
        case .C3: return "C3 · + verification"
        case .C3_repair: return "C3 + one repair retry"
        }
    }
}

/// One message through one config: everything the trajectory file records.
struct RunResult {
    var item: Item
    var config: LadderConfig
    var raw: String
    var parseError: String?
    var before: Action?          // schema-valid model action before verification
    var final: Action?           // what the user gets
    var verdict: Verdict?
    var recovery: String?
    var repair: JObj?
    var info: GenInfo
    var verifyMs: Double?
    var device: DeviceSnapshot
    var today: String

    var decision: String {
        guard let final else { return "invalid" }
        switch final {
        case .clarify: return "clarify"
        case .none: return "none"
        default: return "act"
        }
    }

    func predRow() -> JObj { toPred(item.id, final) }

    func trajectoryRow(backend: String) -> JObj {
        var t = JObj()
        t["id"] = .str(item.id)
        t["config"] = .str(config.rawValue)
        t["backend"] = .str(backend)
        t["raw_output"] = .str(raw)
        t["schema_valid"] = .bool(parseError == nil)
        t["parse_error"] = parseError.map { .str($0) } ?? .null
        t["pred_before_verify"] = config.verify ? .obj(toPred(item.id, before)) : .null
        t["verifier"] = verdict.map { verdictJSON($0, recovery: recovery) } ?? .null
        t["repair"] = repair.map { .obj($0) } ?? .null
        t["decision"] = .str(decision)
        t.merge(infoJSON(info))
        t["model_version"] = .str(backend)
        t["cost_usd"] = .float(0)
        // Phone-only fields
        t["verify_ms"] = verifyMs.map { .float($0) } ?? .null
        t["today_date"] = .str(today)
        t.merge(device.json)
        return t
    }
}

func verdictJSON(_ v: Verdict, recovery: String?) -> JV {
    var details = JObj()
    for k in v.details.keys.sorted() { details[k] = .str(v.details[k]!) }
    return .obj(JObj([("ok", .bool(v.ok)), ("failed", .arr(v.failed.map { .str($0) })),
                      ("clarify_field", v.clarifyField.map { .str($0) } ?? .null),
                      ("details", .obj(details)), ("recovery", recovery.map { .str($0) } ?? .null)]))
}

func infoJSON(_ i: GenInfo) -> JObj {
    JObj([
        ("first_token_ms", i.firstTokenMs.map { .float($0) } ?? .null),
        ("total_ms", .float(i.totalMs)),
        ("input_tokens", .int(i.inputTokens)),
        ("cached_tokens", .int(i.cachedTokens)),
        ("output_tokens", .int(i.outputTokens)),
        ("decode_tok_s", i.decodeTokS.map { .float($0) } ?? .null),
        ("timed_out", .bool(i.timedOut)),
        ("hit_max_tokens", .bool(i.hitMaxTokens)),
        ("finish_reason", i.finishReason.map { .str($0) } ?? .null),
    ])
}

/// Bundled text resources (copied from the repo at build time: prompts/, schemas/, data/dev/).
enum Resources {
    static func text(_ name: String, _ ext: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext),
              let s = try? String(contentsOf: url, encoding: .utf8) else {
            fatalError("missing bundled resource \(name).\(ext)")
        }
        return s
    }
    static let system = text("calendar_v0", "txt")
    static let grammar = text("calendar", "gbnf")
    static let devItems: [Item] = text("calendar_dev", "jsonl").split(separator: "\n").compactMap { line in
        guard case .obj(let o)? = try? parseJSON(String(line)),
              let id = o["id"]?.asString, let m = o["message"]?.asString,
              let r = o["reference_time"]?.asString, let tz = o["tz"]?.asString else { return nil }
        return Item(id: id, message: m, referenceTime: r, tz: tz)
    }
}

let MAX_TOKENS = 160   // as configured for the Mac runs
let TIMEOUT_S = 30.0

/// Runs one item through a config on the given engine (call from the ModelService actor).
func runPipeline(engine: LlamaEngine, item: Item, config: LadderConfig, today: String,
                 sampler: MemorySampler, onText: ((String) -> Void)? = nil) throws -> RunResult {
    let before = DeviceSnapshot.now()
    sampler.start()
    let prompt = chatPrompt(system: Resources.system, user: userMessage(item), today: today)
    let (raw, info) = try engine.generate(prompt: prompt, grammar: config.grammar ? Resources.grammar : nil,
                                          maxTokens: MAX_TOKENS, timeoutS: TIMEOUT_S, onText: onText)
    let (action, err) = parseAction(raw)
    var result = RunResult(item: item, config: config, raw: raw, parseError: err, before: action, final: action,
                           verdict: nil, recovery: nil, repair: nil, info: info, verifyMs: nil,
                           device: before, today: today)
    if config.verify, let action {
        let t0 = CFAbsoluteTimeGetCurrent()
        let v = check(item, action)
        result.verifyMs = ((CFAbsoluteTimeGetCurrent() - t0) * 1000 * 1000).rounded() / 1000
        result.verdict = v
        if !v.ok {
            if config == .C3_repair {
                // ONE capped retry with the failed check as feedback; a second failure -> clarify.
                let why = v.details.keys.sorted().map { "\($0): \(v.details[$0]!)" }.joined(separator: "; ")
                let user2 = userMessage(item) + "\n\nPrevious answer: " + raw + "\n\n"
                    + REPAIR_NOTE.replacingOccurrences(of: "{why}", with: why)
                let (raw2, info2) = try engine.generate(
                    prompt: chatPrompt(system: Resources.system, user: user2, today: today),
                    grammar: Resources.grammar, maxTokens: MAX_TOKENS, timeoutS: TIMEOUT_S, onText: onText)
                let (a2, err2) = parseAction(raw2)
                var final2: Action, v2json: JV
                if let a2 {
                    let v2 = check(item, a2)
                    final2 = v2.ok ? a2 : .clarify([v2.clarifyField!])
                    v2json = verdictJSON(v2, recovery: v2.ok ? nil : "clarify")
                } else {
                    final2 = .clarify([v.clarifyField!])
                    v2json = .obj(JObj([("ok", .bool(false)), ("failed", .arr([.str("schema")])), ("recovery", .str("clarify"))]))
                }
                var rep = JObj([("raw_output", .str(raw2)), ("parse_error", err2.map { .str($0) } ?? .null), ("verifier", v2json)])
                rep.merge(infoJSON(info2))
                result.repair = rep
                result.final = final2
                result.recovery = "repair"
            } else {
                result.final = .clarify([v.clarifyField!])
                result.recovery = "clarify"
            }
        }
    }
    result.device = before.merged(after: DeviceSnapshot.now(), peakMB: sampler.stop())
    return result
}

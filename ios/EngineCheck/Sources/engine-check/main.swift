import CalendarCore
import Foundation

// engine-check <C0|C1|C3> [--limit N] [--fast]   (--fast: lazy grammar + prompt lookup, timed against plain)   (Today Date = each item's reference date, as the Mac runner)
// Compares raw outputs (and, for C3, final decisions) with results/<config>_calendar_dev_trajectory.jsonl.

let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../..").standardized
func read(_ p: String) -> String { (try? String(contentsOf: repo.appendingPathComponent(p), encoding: .utf8)) ?? "" }

var args = Array(CommandLine.arguments.dropFirst())
let config = args.first ?? "C1"
var limit = Int.max
let fast = args.contains("--fast")
if let i = args.firstIndex(of: "--limit") { limit = Int(args[i + 1])! }

let system = read("prompts/calendar_v0.txt")
let grammar = config == "C0" ? nil : read("schemas/calendar.gbnf")
var items: [Item] = []
for line in read("data/dev/calendar_dev.jsonl").split(separator: "\n") {
    guard case .obj(let o) = try parseJSON(String(line)) else { continue }
    items.append(Item(id: o["id"]!.asString!, message: o["message"]!.asString!,
                      referenceTime: o["reference_time"]!.asString!, tz: o["tz"]!.asString!))
}
var mac: [String: JObj] = [:]
for line in read("results/\(config)_calendar_dev_trajectory.jsonl").split(separator: "\n") {
    if case .obj(let o) = try parseJSON(String(line)) { mac[o["id"]!.asString!] = o }
}

let env = ProcessInfo.processInfo.environment
var engineRef: LlamaEngine? = try LlamaEngine(path: repo.appendingPathComponent("models/Llama-3.2-3B-Instruct-Q4_K_M.gguf").path, mmap: true)

if let d = env["LOOKUP"], let k = Int(d) { engineRef!.lookupDraft = k }
if env["LAZY"] == "0" { engineRef!.lazyGrammar = false }
print(String(format: "loaded in %.1f s; config %@; lazyGrammar %@ lookupDraft %d", engineRef!.loadMs / 1000, config,
             engineRef!.lazyGrammar ? "on" : "off", engineRef!.lookupDraft))

var sameRaw = 0, sameDecision = 0, sameTokens = 0, n = 0
var fastSame = 0, totalPasses = 0, totalOut = 0
var plainMs: [Double] = [], fastMs: [Double] = []
func median(_ x: [Double]) -> Double { let s = x.sorted(); return s.isEmpty ? 0 : s[s.count / 2] }
var diffs: [String] = []
for item in items.prefix(limit) {
    let prompt = chatPrompt(system: system, user: userMessage(item), today: templateDate(item))
    var (raw, info) = try engineRef!.generate(prompt: prompt, grammar: grammar, maxTokens: 160, timeoutS: 60)
    if fast {
        let (raw2, info2, passes) = try engineRef!.generateFast(prompt: prompt, grammar: grammar, maxTokens: 160, timeoutS: 60)
        fastSame += raw2 == raw ? 1 : 0
        plainMs.append(info.totalMs - (info.firstTokenMs ?? 0)); fastMs.append(info2.totalMs - (info2.firstTokenMs ?? 0))
        totalPasses += passes; totalOut += info2.outputTokens
        if raw2 != raw { print("FAST DIFF \(item.id)\n  plain: \(raw)\n  fast:  \(raw2)") }
        (raw, info) = (raw2, info2)
    }
    var (action, _) = parseAction(raw)
    if config == "C3", let a = action { action = verify(item, a).0 }
    let decision = action.map { a -> String in
        switch a { case .clarify: return "clarify"; case .none: return "none"; default: return "act" }
    } ?? "invalid"
    n += 1
    let m = mac[item.id]
    let macRaw = m?["raw_output"]?.asString ?? "?"
    if raw == macRaw { sameRaw += 1 } else { diffs.append("\(item.id)\n   phone engine: \(raw)\n   Mac python:   \(macRaw)") }
    if decision == m?["decision"]?.asString { sameDecision += 1 }
    if case .int(let t)? = m?["input_tokens"], t == info.inputTokens { sameTokens += 1 }
    print(String(format: "%@ %@ in=%d cached=%d out=%d first=%.0fms total=%.0fms %@",
                 item.id, raw == macRaw ? "same" : "DIFF", info.inputTokens, info.cachedTokens, info.outputTokens,
                 info.firstTokenMs ?? -1, info.totalMs, decision))
}
print("\nIdentical raw output: \(sameRaw)/\(n); same decision: \(sameDecision)/\(n); same input token count: \(sameTokens)/\(n)")
for d in diffs.prefix(10) { print(d) }
if fast {
    print(String(format: "FAST: identical to plain decoding %d/%d; writing time median plain %.0f ms -> fast %.0f ms (x%.2f); %.2f tokens per forward pass",
                 fastSame, n, median(plainMs), median(fastMs), median(plainMs) / max(1, median(fastMs)), Double(totalOut) / Double(max(1, totalPasses))))
}
engineRef = nil  // free Metal resources before exit (otherwise ggml asserts at teardown)

import CryptoKit
import Foundation
import llama

/// One configuration exported from configs/*.yaml by harness/export_ios_bundle.py.
public struct RunSpec: Codable {
    public let name: String            // e.g. "C2_notes"
    public let config: String          // e.g. "C2"
    public let task: String            // "notes" | "calendar"
    public let system_prompt: String?  // notes: the system prompt (prompts/notes_v0.txt)
    public let grammar: String?        // GBNF text, or nil for no constrained decoding
    public let max_tokens: Int
    public let context_tokens: Int
    public let items: String           // notes: items .jsonl; calendar: pre-rendered prompts .jsonl
    public let corpus: String?
    public let retrieval: RetrievalSpec?

    public struct RetrievalSpec: Codable {
        public let method: String      // "bm25" | "hybrid"
        public let top_k: Int
        public let rrf_k: Int?
        public let bm25_candidates: Int?
        public let embedding_file: String?
        public let query_prefix: String?
        public let doc_prefix: String?
    }
}

public struct Manifest: Codable {
    public let model_file: String
    public let model_sha256: String
    public let llama_cpp: String
    public let gate_ids: [String: [String]]   // task -> item ids for the feasibility gate
    public let runs: [RunSpec]
}

/// How to pace requests: back-to-back, one every N seconds (sustained run), or for a fixed time.
public struct Pacing {
    public var secondsBetweenStarts: Double = 0
    public var durationLimitS: Double? = nil   // stop after this long, cycling items (stress run)
    public init(secondsBetweenStarts: Double = 0, durationLimitS: Double? = nil) {
        self.secondsBetweenStarts = secondsBetweenStarts; self.durationLimitS = durationLimitS
    }
}

func readJSONL(_ url: URL) throws -> [[String: Any]] {
    try String(contentsOf: url, encoding: .utf8).split(separator: "\n").compactMap {
        try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
    }
}

func jsonLine(_ obj: Any) -> String {
    let d = try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])
    return String(decoding: d, as: UTF8.self)
}

func sha256(_ s: String) -> String { SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined() }

/// Runs a RunSpec item by item and writes <out>/pred.jsonl, trajectory.jsonl and memory.csv,
/// in the same formats as the Mac harness, plus device fields (memory, thermal state, timing).
public final class ReplayRunner {
    let bundle: URL, modelDir: URL
    public let manifest: Manifest
    private var model: LlamaModel?
    private var session: LlamaSession?

    public init(bundle: URL, modelDir: URL) throws {
        self.bundle = bundle; self.modelDir = modelDir
        manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: bundle.appendingPathComponent("manifest.json")))
    }

    /// Loads the main model once (timed); later runs reuse it.
    public func loadModel(log: (String) -> Void) throws -> Double {
        if session != nil { return 0 }
        let t0 = Date()
        let m = try LlamaModel(path: modelDir.appendingPathComponent(manifest.model_file).path, mmap: false)
        session = try LlamaSession(model: m, contextTokens: 4096)
        model = m
        let s = Date().timeIntervalSince(t0)
        log(String(format: "model loaded in %.1f s", s))
        return s
    }

    public func run(_ spec: RunSpec, ids: Set<String>? = nil, limit: Int? = nil, pacing: Pacing = Pacing(),
                    out: URL, battery: () -> Double? = { nil }, shouldStop: () -> Bool = { false },
                    log: (String) -> Void) throws {
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let loadS = try loadModel(log: log)
        guard let model, let session else { throw CoreError.model("not loaded") }

        var items = try readJSONL(bundle.appendingPathComponent(spec.items))
        if let ids { items = items.filter { ids.contains($0["id"] as? String ?? "") } }
        if let limit { items = Array(items.prefix(limit)) }
        var retriever: Retriever?
        var notesByID: [String: Note] = [:]
        if spec.task == "notes" {
            let notes = try readJSONL(bundle.appendingPathComponent(spec.corpus!)).map {
                Note(id: $0["id"] as! String, title: $0["title"] as! String, body: $0["body"] as! String)
            }
            notesByID = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0) })
            let r = spec.retrieval!
            let bm25 = try BM25Index(notes: notes)
            if r.method == "hybrid" {
                let emb = try Embedder(path: modelDir.appendingPathComponent(r.embedding_file!).path)
                let dense = try DenseIndex(notes: notes, embedder: emb, queryPrefix: r.query_prefix ?? "", docPrefix: r.doc_prefix ?? "")
                retriever = HybridIndex(bm25: bm25, dense: dense, rrfK: r.rrf_k ?? 60, candidates: r.bm25_candidates ?? 10)
            } else {
                retriever = bm25
            }
        }

        let sampler = MemorySampler()
        sampler.start()
        defer { sampler.stop() }
        var preds: [String] = [], traj: [String] = []
        let runStart = Date()
        var thermalEvents: [String] = []
        let obs = NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil) { _ in
            thermalEvents.append(jsonLine(["t_s": Date().timeIntervalSince(runStart), "thermal_state": DeviceMetrics.thermalState()]))
        }
        defer { NotificationCenter.default.removeObserver(obs) }
        _ = sampler.mark()

        var n = 0
        var cycle = 0
        outer: while true {
            for it in items {
                if shouldStop() { break outer }
                let elapsed = Date().timeIntervalSince(runStart)
                if let lim = pacing.durationLimitS, elapsed >= lim { break outer }
                if pacing.secondsBetweenStarts > 0 {
                    let due = Double(n) * pacing.secondsBetweenStarts
                    if due > elapsed { Thread.sleep(forTimeInterval: due - elapsed) }
                }
                let tStart = Date().timeIntervalSince(runStart)
                let thermalBefore = DeviceMetrics.thermalState()
                let batteryBefore = battery()
                let id = it["id"] as! String
                var p: [String: Any] = ["id": id]
                var t: [String: Any] = ["id": id, "config": spec.config, "cycle": cycle, "t_start_s": tStart,
                                        "thermal_state_before": thermalBefore]
                let prompt: String
                if spec.task == "notes" {
                    let item = NotesItem(it)!
                    let ref = ReferenceTime(iso: item.referenceTime)!
                    let tr0 = Date()
                    let hits = retriever!.search(item.question, k: spec.retrieval!.top_k)
                    t["retrieval_ms"] = Date().timeIntervalSince(tr0) * 1000
                    prompt = ChatPrompt.renderLlama32(system: spec.system_prompt!,
                                                      user: NotesTask.userMessage(question: item.question, ref: ref, hits: hits), ref: ref)
                    let retrieved = hits.map(\.noteID)
                    t["retrieved"] = hits.map { ["note_id": $0.noteID, "score": ($0.score * 10000).rounded() / 10000] }
                    t["retrieval_hit"] = item.support.isEmpty ? NSNull() : !Set(item.support).isDisjoint(with: retrieved)
                    let g = try session.generate(promptTokens: model.tokenize(prompt, addSpecial: false, parseSpecial: true),
                                                 grammar: spec.grammar, maxTokens: spec.max_tokens)
                    let (answer, cits, ok) = NotesTask.parseOutput(g.text)
                    let abstain = NotesTask.isAbstain(answer)
                    p.merge(["answer": answer, "citations": cits.map { ["note_id": $0.note_id, "quote": $0.quote] },
                             "abstained": abstain, "format_ok": ok]) { $1 }
                    t.merge(["format_ok": ok, "cited_ids_retrieved": cits.allSatisfy { retrieved.contains($0.note_id) },
                             "quotes_verbatim": cits.allSatisfy { c in
                                 (notesByID[c.note_id]?.body.lowercased() ?? "").contains(c.quote.lowercased()) },
                             "decision": abstain ? "abstain" : "answer"]) { $1 }
                    t.merge(genFields(g)) { $1 }
                } else {
                    prompt = it["prompt"] as! String
                    let g = try session.generate(promptTokens: model.tokenize(prompt, addSpecial: false, parseSpecial: true),
                                                 grammar: spec.grammar, maxTokens: spec.max_tokens)
                    p["raw_output"] = g.text   // parsed and scored on the Mac (harness/score_ios_calendar.py)
                    t.merge(genFields(g)) { $1 }
                }
                let (peak, minAvail) = sampler.mark()
                t["prompt_sha256"] = sha256(prompt)
                t["footprint_peak_mb"] = (peak * 10).rounded() / 10
                t["available_min_mb"] = minAvail.map { ($0 * 10).rounded() / 10 } ?? NSNull()
                t["thermal_state_after"] = DeviceMetrics.thermalState()
                t["battery_before"] = batteryBefore ?? NSNull()
                t["battery_after"] = battery() ?? NSNull()
                preds.append(jsonLine(p)); traj.append(jsonLine(t))
                n += 1
                log("[\(n)] \(id) \(t["total_ms"] ?? "") ms, \(DeviceMetrics.thermalState()), peak \(Int(peak)) MB")
            }
            cycle += 1
            if pacing.durationLimitS == nil { break }
        }

        try (preds.joined(separator: "\n") + "\n").write(to: out.appendingPathComponent("pred.jsonl"), atomically: true, encoding: .utf8)
        try (traj.joined(separator: "\n") + "\n").write(to: out.appendingPathComponent("trajectory.jsonl"), atomically: true, encoding: .utf8)
        try sampler.csv().write(to: out.appendingPathComponent("memory.csv"), atomically: true, encoding: .utf8)
        let summary: [String: Any] = [
            "run": spec.name, "requests": n, "model_load_s": loadS, "wall_s": Date().timeIntervalSince(runStart),
            "peak_footprint_mb": sampler.runPeakMB, "min_available_mb": sampler.runMinAvailableMB ?? NSNull(),
            "thermal_events": thermalEvents, "llama_cpp": manifest.llama_cpp, "model_sha256": manifest.model_sha256,
        ]
        try jsonLine(summary).write(to: out.appendingPathComponent("summary.json"), atomically: true, encoding: .utf8)
        log(String(format: "done: %d requests, peak footprint %.0f MB", n, sampler.runPeakMB))
    }

    private func genFields(_ g: Generation) -> [String: Any] {
        ["raw_output": g.text, "prompt_tokens": g.promptTokens, "cached_tokens": g.cachedTokens, "gen_tokens": g.genTokens,
         "first_token_ms": g.firstTokenMs ?? NSNull(), "total_ms": g.totalMs, "decode_tok_s": g.decodeTokS ?? NSNull()]
    }
}

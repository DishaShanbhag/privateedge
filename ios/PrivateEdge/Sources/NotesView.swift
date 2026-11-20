import CalendarCore
import PrivateEdgeCore
import SwiftUI

/// The notes screen: ask a question, the app searches the 49 dev notes on the phone and answers with
/// citations, or says "the notes don't say". Uses Yash's PrivateEdgeCore (retrieval, prompt, parsing)
/// with the run settings exported from configs/ (ios/Bundle/manifest.json), and the app's shared
/// model, so calendar and notes never hold two copies of the weights.
struct NotesView: View {
    @EnvironmentObject var app: AppModel
    @State private var question = ""
    @State private var runName = "C2_notes"
    @State private var streaming = ""
    @State private var result: NotesResult?
    @State private var running = false
    @State private var error: String?

    // From the dev set (answers: tangerine-4471; 0629; Tue 3pm with Dr. Patel; the notes disagree;
    // phone yes, email not in the notes; and one the notes cannot answer).
    private let examples = ["What's the wifi password?", "What's my bike lock combination?",
                            "When is my doctor's appointment?", "What are the gym's weekend hours?",
                            "What's my landlord's phone number and email?", "What is my passport number?"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Ask about your notes…", text: $question, axis: .vertical)
                        .lineLimit(1...4)
                        .onSubmit(run)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(examples, id: \.self) { ex in
                                Button(ex) { question = ex }.buttonStyle(.bordered).controlSize(.small)
                            }
                        }
                    }
                    Picker("Pipeline", selection: $runName) {
                        Text("C0").tag("C0_notes")
                        Text("C1").tag("C1_notes")
                        Text("C2").tag("C2_notes")
                    }
                    .pickerStyle(.segmented)
                    Button(action: run) {
                        HStack {
                            if running { ProgressView().padding(.trailing, 4) }
                            Text(running ? "Searching and thinking on device…" : "Ask")
                        }.frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(running || question.trimmingCharacters(in: .whitespaces).isEmpty || !ready)
                } footer: {
                    VStack(alignment: .leading) {
                        Text("C0: keyword search, prompt only · C1: + grammar · C2: + hybrid search (keywords + embeddings)")
                        if !ready { ModelStatusLine() }
                    }
                }

                if let r = result {
                    Section("Found notes (\(r.searchMs < 1 ? "<1" : String(format: "%.0f", r.searchMs)) ms)") {
                        ForEach(r.hits, id: \.noteID) { h in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("[\(h.noteID)] \(h.title)").font(.footnote.bold())
                                Text(h.body).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                            }
                        }
                    }
                }
                if running || result != nil {
                    Section("Model output") {
                        Text(result?.raw ?? streaming).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                    }
                }
                if let r = result {
                    Section("Answer") {
                        if !r.formatOK {
                            Label("The model's answer was not in the required format", systemImage: "xmark.octagon").foregroundStyle(.red)
                        }
                        if r.abstained {
                            Label("The notes don't say.", systemImage: "questionmark.circle")
                        } else {
                            Text(r.answer).font(.headline)
                        }
                        ForEach(Array(r.citations.enumerated()), id: \.offset) { _, c in
                            let ok = r.quoteFound(c)
                            Label("[\(c.note_id)] “\(c.quote)”", systemImage: ok ? "quote.opening" : "exclamationmark.triangle")
                                .font(.footnote)
                                .foregroundStyle(ok ? Color.secondary : Color.orange)
                        }
                        if r.citations.contains(where: { !r.quoteFound($0) }) {
                            Text("Orange: the quote is not in that note word for word.").font(.caption).foregroundStyle(.orange)
                        }
                    }
                    Section("On-device cost") {
                        Grid(alignment: .leading, verticalSpacing: 4) {
                            GridRow { Text("First token").foregroundStyle(.secondary); Text(r.info.firstTokenMs.map { String(format: "%.0f ms", $0) } ?? "-") }
                            GridRow { Text("Total").foregroundStyle(.secondary); Text(String(format: "%.2f s", r.info.totalMs / 1000)) }
                            GridRow { Text("Tokens in / out").foregroundStyle(.secondary); Text("\(r.info.inputTokens) / \(r.info.outputTokens)") }
                            GridRow { Text("Network").foregroundStyle(.secondary); Text("none (runs fully on device)") }
                        }.font(.footnote)
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle("Notes")
        }
    }

    private var ready: Bool { if case .ready = app.state { return true }; return false }

    private func run() {
        guard ready, !running else { return }
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        running = true; result = nil; error = nil; streaming = ""
        let name = runName
        Task {
            do {
                result = try await app.service.answerNote(q, runName: name) { text in
                    Task { @MainActor in streaming = text }
                }
            } catch {
                self.error = "\(error)"
            }
            running = false
        }
    }
}

struct NotesResult {
    var hits: [Hit]
    var searchMs: Double
    var raw: String
    var answer: String
    var citations: [Citation]
    var abstained: Bool
    var formatOK: Bool
    var info: GenInfo
    var notes: [String: Note]

    func quoteFound(_ c: Citation) -> Bool {
        (notes[c.note_id]?.body.lowercased() ?? "").contains(c.quote.lowercased())
    }
}

/// Notes resources: the exported bundle (manifest, corpus) and the search indexes, built on first use.
final class NotesEngine {
    let manifest: Manifest
    let notes: [Note]
    private var bm25: BM25Index?
    private var hybrid: HybridIndex?
    let bundleDir: URL

    init() throws {
        guard let b = Bundle.main.url(forResource: "Bundle", withExtension: nil) else {
            throw CoreError.model("Notes bundle missing: run python harness/export_ios_bundle.py, then make_project.sh")
        }
        bundleDir = b
        manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: b.appendingPathComponent("manifest.json")))
        let spec = manifest.runs.first { $0.task == "notes" }!
        let text = try String(contentsOf: b.appendingPathComponent(spec.corpus!), encoding: .utf8)
        // Note is Codable; extra keys in the corpus rows are ignored.
        notes = text.components(separatedBy: "\n").filter { !$0.isEmpty }.compactMap { line -> Note? in
            try? JSONDecoder().decode(Note.self, from: Data(line.utf8))
        }
    }

    func spec(_ name: String) -> RunSpec { manifest.runs.first { $0.name == name }! }

    func retriever(for spec: RunSpec) throws -> Retriever {
        if bm25 == nil { bm25 = try BM25Index(notes: notes) }
        let r = spec.retrieval!
        guard r.method == "hybrid" else { return bm25! }
        if hybrid == nil {
            let path = try modelDirectory().appendingPathComponent(r.embedding_file!).path
            let emb = try Embedder(path: path)
            let dense = try DenseIndex(notes: notes, embedder: emb, queryPrefix: r.query_prefix ?? "", docPrefix: r.doc_prefix ?? "")
            hybrid = HybridIndex(bm25: bm25!, dense: dense, rrfK: r.rrf_k ?? 60, candidates: r.bm25_candidates ?? 10)
        }
        return hybrid!
    }
}

/// Where the model files are: inside the app (copied from models/ at build time), else Documents.
func modelDirectory() throws -> URL {
    if let res = Bundle.main.resourceURL, FileManager.default.fileExists(atPath: res.appendingPathComponent(MODEL_FILE).path) {
        return res
    }
    return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
}

extension ModelService {
    func answerNote(_ question: String, runName: String, onText: (@Sendable (String) -> Void)? = nil) throws -> NotesResult {
        let ne = try notesEngine()
        let spec = ne.spec(runName)
        let t0 = CFAbsoluteTimeGetCurrent()
        let hits = try ne.retriever(for: spec).search(question, k: spec.retrieval!.top_k)
        let searchMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        let ref = ReferenceTime(iso: nowItem("").referenceTime)!
        let prompt = ChatPrompt.renderLlama32(system: spec.system_prompt!,
                                              user: NotesTask.userMessage(question: question, ref: ref, hits: hits), ref: ref)
        let (raw, info) = try generate(prompt: prompt, grammar: spec.grammar, maxTokens: spec.max_tokens, onText: onText)
        let (answer, cits, ok) = NotesTask.parseOutput(raw)
        return NotesResult(hits: hits, searchMs: searchMs, raw: raw, answer: answer, citations: cits,
                           abstained: NotesTask.isAbstain(answer), formatOK: ok, info: info,
                           notes: Dictionary(uniqueKeysWithValues: ne.notes.map { ($0.id, $0) }))
    }
}

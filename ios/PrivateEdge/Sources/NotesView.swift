import CalendarCore
import PrivateEdgeCore
import SwiftUI

struct NotesTurn: Identifiable {
    let id = UUID()
    let question: String
    var result: NotesResult?
    var error: String?
    let started = Date()
}

/// The notes screen: ask a question about your notes. The app searches them on the phone and answers
/// with the notes it used, or says the notes don't say. Uses Yash's PrivateEdgeCore (retrieval,
/// prompt, parsing) with the settings exported from configs/, and the app's shared model.
struct NotesView: View {
    @EnvironmentObject var app: AppModel
    @AppStorage("notesPipeline") private var runName = "C2_notes"
    @State private var input = ""
    @State private var turns: [NotesTurn] = []
    @State private var partial = ""
    @State private var running = false
    @State private var showSettings = false

    private let examples = ["What's the wifi password?", "When is my doctor's appointment?",
                            "What are the gym's weekend hours?", "What is my passport number?"]

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        PrivacyPill()
                        ModelBanner()
                        if turns.isEmpty {
                            VStack(alignment: .leading, spacing: 14) {
                                Text("Ask anything about your notes. I only answer from what they say, show you where it came from, and tell you when they don't say.")
                                    .font(.callout).foregroundStyle(.secondary)
                                ExampleChips(title: "Try one:", examples: examples) { send($0) }
                            }
                        }
                        ForEach(turns) { t in
                            UserBubble(text: t.question)
                            if let r = t.result {
                                NotesAnswerCard(result: r)
                            } else if let e = t.error {
                                AnswerCard(icon: "xmark", color: .red, kind: "Something went wrong") { Text(e).font(.callout) }
                            } else {
                                ThinkingCard(started: t.started, partial: partial)
                            }
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding()
                }
                .background(Color(.systemGroupedBackground))
                .onChange(of: turns.count) { withAnimation { proxy.scrollTo("bottom") } }
                .onChange(of: running) { withAnimation { proxy.scrollTo("bottom") } }
            }
            .safeAreaInset(edge: .bottom) {
                ChatInputBar(text: $input, placeholder: "Ask about your notes…", busy: running, enabled: ready) { send(input) }
            }
            .navigationTitle("Notes")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if !turns.isEmpty { Button("Clear conversation", systemImage: "trash") { turns = [] } }
                        Picker("Search", selection: $runName) {
                            Text("C2: keywords + meaning (recommended)").tag("C2_notes")
                            Text("C1: keywords + strict format").tag("C1_notes")
                            Text("C0: keywords, prompt only").tag("C0_notes")
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .onChange(of: ready) { if ready, let demo = demoArgument("-demoNotes"), turns.isEmpty { send(demo) } }
        }
    }

    private var ready: Bool { if case .ready = app.state { return true }; return false }

    private func send(_ text: String) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ready, !running, !q.isEmpty else { return }
        input = ""
        turns.append(NotesTurn(question: q))
        let idx = turns.count - 1
        running = true; partial = ""
        let name = runName
        Task {
            do {
                turns[idx].result = try await app.service.answerNote(q, runName: name) { text in
                    Task { @MainActor in partial = text }
                }
            } catch {
                turns[idx].error = "\(error)"
            }
            running = false
        }
    }
}

struct NotesAnswerCard: View {
    let result: NotesResult
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !result.formatOK {
                AnswerCard(icon: "exclamationmark", color: .red, kind: "Didn't understand") {
                    Text("Sorry, the answer came out garbled. Try asking another way.").font(.callout)
                }
            } else if result.abstained {
                AnswerCard(icon: "questionmark", color: .gray, kind: "Not in your notes") {
                    Text("Your notes don't say.").font(.title3.weight(.semibold))
                    Text("I'd rather tell you that than make something up.").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                AnswerCard(icon: "text.quote", color: .indigo, kind: "From your notes") {
                    Text(result.answer).font(.title3.weight(.semibold)).textSelection(.enabled)
                    ForEach(Array(result.citations.enumerated()), id: \.offset) { _, c in
                        let ok = result.quoteFound(c)
                        VStack(alignment: .leading, spacing: 2) {
                            Label(result.notes[c.note_id]?.title ?? c.note_id, systemImage: "note.text")
                                .font(.caption.weight(.semibold))
                            Text("“\(c.quote)”").font(.caption).foregroundStyle(.secondary)
                            if !ok { Text("This quote isn't word for word in that note.").font(.caption2).foregroundStyle(.orange) }
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            DisclosureGroup("Details") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Notes searched (\(String(format: "%.0f", result.searchMs)) ms):").font(.caption.weight(.semibold))
                    ForEach(result.hits, id: \.noteID) { h in Text("[\(h.noteID)] \(h.title)").font(.caption2) }
                    Text(result.raw).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                    Text(String(format: "First word %.0f ms · total %.1f s · %d tokens in / %d out · no network",
                                result.info.firstTokenMs ?? -1, result.info.totalMs / 1000,
                                result.info.inputTokens, result.info.outputTokens)).font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.top, 6)
            }
            .font(.caption).tint(.secondary).padding(.horizontal, 4)
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

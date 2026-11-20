import CalendarCore
import CryptoKit
import Foundation
import SwiftUI

let MODEL_FILE = "Llama-3.2-3B-Instruct-Q4_K_M.gguf"
let MODEL_SHA256 = "6c1a2b41161032677be168d354123594c0e6e67d2b9227c84f296ad037c728ff"  // configs/_base.yaml
let BACKEND_NAME = "Llama-3.2-3B-Instruct-Q4_K_M"
let LLAMA_CPP = "llama.cpp b12387 (a956a852c)"

/// Owns the engine; every model call runs here, one at a time.
actor ModelService {
    private var engine: LlamaEngine?
    private let sampler = MemorySampler()

    func load(path: String, mmap: Bool, gpu: Bool) throws -> Double {
        engine = nil  // free the old one first: two copies of the weights do not fit
        let e = try LlamaEngine(path: path, mmap: mmap, gpu: gpu)
        engine = e
        return e.loadMs
    }

    /// Frees the weights (the Measure tab loads its own copy through Yash's ReplayRunner).
    func unload() { engine = nil }

    private var notes: NotesEngine?
    func notesEngine() throws -> NotesEngine {
        if notes == nil { notes = try NotesEngine() }
        return notes!
    }

    func generate(prompt: String, grammar: String?, maxTokens: Int,
                  onText: (@Sendable (String) -> Void)? = nil) throws -> (String, GenInfo) {
        guard let engine else { throw EngineError.context }
        return try engine.generate(prompt: prompt, grammar: grammar, maxTokens: maxTokens, timeoutS: TIMEOUT_S, onText: onText)
    }

    func run(_ item: Item, _ config: LadderConfig, today: String,
             onText: (@Sendable (String) -> Void)? = nil) throws -> RunResult {
        guard let engine else { throw EngineError.context }
        return try runPipeline(engine: engine, item: item, config: config, today: today, sampler: sampler, onText: onText)
    }
}

enum LoadState: Equatable {
    case missing, idle, loading, ready(Double), failed(String)
}

@MainActor
final class AppModel: ObservableObject {
    @Published var state: LoadState = .idle
    @Published var shaState = "not checked"
    @Published var useMmap = ProcessInfo.processInfo.arguments.contains("-mmap")  // protocol: mmap off
    /// Metal on a device. In the Simulator, CPU: the Simulator's Metal crashes loading the weights
    /// with mmap off and produces garbage with mmap on (tested 2026-11-19), so it stays off there.
    #if targetEnvironment(simulator)
    @Published var useGPU = ProcessInfo.processInfo.arguments.contains("-simGPU")
    #else
    @Published var useGPU = true
    #endif
    let service = ModelService()

    /// The model ships inside the app (copied from models/ at build time) or can be dropped into
    /// the app's Documents folder with the Files app or Finder.
    var modelPath: String? {
        if let p = Bundle.main.path(forResource: MODEL_FILE, ofType: nil) { return p }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(MODEL_FILE)
        return FileManager.default.fileExists(atPath: docs.path) ? docs.path : nil
    }

    var modelSizeGB: String {
        guard let p = modelPath, let a = try? FileManager.default.attributesOfItem(atPath: p),
              let n = a[.size] as? NSNumber else { return "-" }
        return String(format: "%.2f GB", n.doubleValue / 1e9)
    }

    func unload() async {
        await service.unload()
        state = .idle
    }

    func load() {
        guard let path = modelPath else { state = .missing; return }
        if case .loading = state { return }
        state = .loading
        let mmap = useMmap, gpu = useGPU
        Task {
            do {
                let ms = try await service.load(path: path, mmap: mmap, gpu: gpu)
                state = .ready(ms)
                await autorun()
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// Test hook: launch with `-autorun "message"` to run it through C3 once the model loads and
    /// print the result to the console (used to check the app without tapping).
    /// `-autonotes "question"` does the same for a notes question with C2.
    private func autorun() async {
        let args = ProcessInfo.processInfo.arguments
        if let j = args.firstIndex(of: "-autonotes"), j + 1 < args.count {
            do {
                let r = try await service.answerNote(args[j + 1], runName: "C2_notes")
                NSLog("%@", "AUTONOTES C2 search=\(r.searchMs)ms hits=\(r.hits.map(\.noteID)) first=\(r.info.firstTokenMs ?? -1)ms total=\(r.info.totalMs)ms answer=\(r.answer) citations=\(r.citations.map(\.note_id)) abstained=\(r.abstained) format_ok=\(r.formatOK)")
            } catch {
                NSLog("%@", "AUTONOTES error \(error)")
            }
        }
        guard let i = args.firstIndex(of: "-autorun"), i + 1 < args.count else { return }
        let configs = args.contains("-allConfigs") ? [LadderConfig.C0, .C1, .C3] : [.C3]
        for cfg in configs {
            do {
                let r = try await service.run(nowItem(args[i + 1]), cfg, today: llamaToday())
                NSLog("%@", "AUTORUN \(cfg.rawValue) gpu=\(useGPU) first=\(r.info.firstTokenMs ?? -1)ms total=\(r.info.totalMs)ms out=\(r.info.outputTokens) decision=\(r.decision) raw=\(r.raw)")
            } catch {
                NSLog("%@", "AUTORUN error \(error)")
            }
        }
    }

    /// SHA-256 of the weights against the pinned value (takes a few seconds; cached per file).
    func checkSHA() {
        guard let path = modelPath else { return }
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let key = "sha:\(path):\((attrs?[.size] as? NSNumber)?.intValue ?? 0):\((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        if let cached = UserDefaults.standard.string(forKey: key) { shaState = verdict(cached); return }
        shaState = "checking…"
        Task.detached(priority: .utility) {
            let hex = Self.sha256(path)
            await MainActor.run {
                if let hex { UserDefaults.standard.set(hex, forKey: key) }
                self.shaState = hex.map { self.verdict($0) } ?? "could not read file"
            }
        }
    }

    private func verdict(_ hex: String) -> String {
        hex == MODEL_SHA256 ? "matches the pinned SHA-256 ✓" : "DOES NOT MATCH the pinned SHA-256 (\(hex.prefix(12))…)"
    }

    nonisolated static func sha256(_ path: String) -> String? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try? h.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// "Now" for a typed message: the device clock and time zone.
func nowItem(_ message: String) -> Item {
    let tz = TimeZone.current
    let ref = ZDT.at(epoch: Int(Date().timeIntervalSince1970), in: tz).iso
    return Item(id: "typed", message: message, referenceTime: ref, tz: tz.identifier)
}

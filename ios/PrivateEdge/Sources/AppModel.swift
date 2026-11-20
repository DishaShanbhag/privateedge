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

    func load(path: String, mmap: Bool) throws -> Double {
        engine = nil  // free the old one first: two copies of the weights do not fit
        let e = try LlamaEngine(path: path, mmap: mmap)
        engine = e
        return e.loadMs
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
    @Published var useMmap = false  // the protocol measures memory with mmap off
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

    func load() {
        guard let path = modelPath else { state = .missing; return }
        if case .loading = state { return }
        state = .loading
        let mmap = useMmap
        Task {
            do {
                let ms = try await service.load(path: path, mmap: mmap)
                state = .ready(ms)
            } catch {
                state = .failed(error.localizedDescription)
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

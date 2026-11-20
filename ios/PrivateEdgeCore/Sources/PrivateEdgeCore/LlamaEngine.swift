import Foundation
import llama

private let backendOnce: Void = { llama_backend_init() }()

/// A loaded GGUF model. Settings match the Mac harness (llama-cpp-python 0.3.37 defaults):
/// all layers on the GPU, flash attention off, batch 512, greedy sampling with the grammar first.
public final class LlamaModel {
    let model: OpaquePointer
    let vocab: OpaquePointer

    /// `mmap: false` reads the weights into memory, as the measurement protocol requires.
    public init(path: String, mmap: Bool = false) throws {
        _ = backendOnce
        var mp = llama_model_default_params()
        mp.n_gpu_layers = -1
        mp.load_mode = mmap ? LLAMA_LOAD_MODE_MMAP : LLAMA_LOAD_MODE_NONE
        guard let m = llama_model_load_from_file(path, mp) else { throw CoreError.model("cannot load \(path)") }
        model = m
        vocab = llama_model_get_vocab(m)
    }

    deinit { llama_model_free(model) }

    public func tokenize(_ text: String, addSpecial: Bool, parseSpecial: Bool) -> [llama_token] {
        let n = Int32(text.utf8.count)
        var buf = [llama_token](repeating: 0, count: Int(n) + 8)
        var got = llama_tokenize(vocab, text, n, &buf, Int32(buf.count), addSpecial, parseSpecial)
        if got < 0 {
            buf = [llama_token](repeating: 0, count: Int(-got))
            got = llama_tokenize(vocab, text, n, &buf, Int32(buf.count), addSpecial, parseSpecial)
        }
        return Array(buf.prefix(Int(max(got, 0))))
    }

    func piece(_ token: llama_token) -> [UInt8] {
        var buf = [CChar](repeating: 0, count: 64)
        var n = llama_token_to_piece(vocab, token, &buf, Int32(buf.count), 0, false)
        if n < 0 {
            buf = [CChar](repeating: 0, count: Int(-n))
            n = llama_token_to_piece(vocab, token, &buf, Int32(buf.count), 0, false)
        }
        return buf.prefix(Int(max(n, 0))).map { UInt8(bitPattern: $0) }
    }
}

public struct Generation {
    public let text: String
    public let promptTokens: Int
    public let genTokens: Int
    public let firstTokenMs: Double?
    public let totalMs: Double
    public let decodeTokS: Double?
}

/// One text-generation context (4K tokens). The KV cache is cleared before every request.
public final class LlamaSession {
    let model: LlamaModel
    let ctx: OpaquePointer
    let nBatch: Int

    public init(model: LlamaModel, contextTokens: Int = 4096, batch: Int = 512) throws {
        var cp = llama_context_default_params()
        cp.n_ctx = UInt32(contextTokens)
        cp.n_batch = UInt32(batch)
        cp.n_ubatch = UInt32(batch)
        cp.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_DISABLED
        cp.offload_kqv = true
        guard let c = llama_init_from_model(model.model, cp) else { throw CoreError.model("cannot create context") }
        self.model = model
        ctx = c
        nBatch = batch
    }

    deinit { llama_free(ctx) }

    /// Greedy decoding, optionally constrained by a GBNF grammar (root rule "root").
    public func generate(promptTokens: [llama_token], grammar: String?, maxTokens: Int) throws -> Generation {
        llama_memory_clear(llama_get_memory(ctx), true)
        guard let chain = llama_sampler_chain_init(llama_sampler_chain_default_params()) else {
            throw CoreError.model("sampler")
        }
        defer { llama_sampler_free(chain) }
        if let g = grammar {
            guard let gs = llama_sampler_init_grammar(model.vocab, g, "root") else { throw CoreError.model("bad grammar") }
            llama_sampler_chain_add(chain, gs)
        }
        llama_sampler_chain_add(chain, llama_sampler_init_greedy())

        let t0 = DispatchTime.now().uptimeNanoseconds
        var tokens = promptTokens
        var i = 0
        while i < tokens.count {
            let n = min(nBatch, tokens.count - i)
            let rc = tokens.withUnsafeMutableBufferPointer { buf in
                llama_decode(ctx, llama_batch_get_one(buf.baseAddress! + i, Int32(n)))
            }
            guard rc == 0 else { throw CoreError.decode("prompt decode returned \(rc)") }
            i += n
        }
        var bytes: [UInt8] = []
        var tFirst: UInt64?
        var generated = 0
        while generated < maxTokens {
            var tok = llama_sampler_sample(chain, ctx, -1)
            if llama_vocab_is_eog(model.vocab, tok) { break }
            generated += 1
            let p = model.piece(tok)
            if tFirst == nil, !p.isEmpty { tFirst = DispatchTime.now().uptimeNanoseconds }
            bytes += p
            if generated == maxTokens { break }  // the last sampled token is never evaluated
            let rc = llama_decode(ctx, llama_batch_get_one(&tok, 1))
            guard rc == 0 else { throw CoreError.decode("token decode returned \(rc)") }
        }
        let tEnd = DispatchTime.now().uptimeNanoseconds
        let text = String(decoding: bytes, as: UTF8.self)
        let nTok = text.isEmpty ? 0 : model.tokenize(text, addSpecial: false, parseSpecial: false).count
        let decodeS = tFirst.map { Double(tEnd - $0) / 1e9 } ?? 0
        return Generation(
            text: text, promptTokens: promptTokens.count, genTokens: nTok,
            firstTokenMs: tFirst.map { (Double($0 - t0) / 1e6 * 10).rounded() / 10 },
            totalMs: (Double(tEnd - t0) / 1e6 * 10).rounded() / 10,
            decodeTokS: decodeS > 0 && nTok > 1 ? (Double(nTok - 1) / decodeS * 10).rounded() / 10 : nil)
    }
}

/// Sentence embeddings with a GGUF embedding model (e.g. bge-small), L2-normalised.
public final class Embedder {
    let model: LlamaModel
    let ctx: OpaquePointer
    let nEmbd: Int

    public init(path: String) throws {
        model = try LlamaModel(path: path, mmap: false)
        var cp = llama_context_default_params()
        cp.n_ctx = 512
        cp.n_batch = 512
        cp.n_ubatch = 512
        cp.embeddings = true
        cp.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_DISABLED
        guard let c = llama_init_from_model(model.model, cp) else { throw CoreError.model("embedding context") }
        ctx = c
        nEmbd = Int(llama_model_n_embd(model.model))
    }

    deinit { llama_free(ctx) }

    public func embed(_ text: String) throws -> [Float] {
        var tokens = model.tokenize(text, addSpecial: true, parseSpecial: false)
        if tokens.count > 512 { tokens = Array(tokens.prefix(512)) }
        llama_memory_clear(llama_get_memory(ctx), true)
        let rc = tokens.withUnsafeMutableBufferPointer { llama_decode(ctx, llama_batch_get_one($0.baseAddress!, Int32($0.count))) }
        guard rc == 0 else { throw CoreError.decode("embedding decode returned \(rc)") }
        var v: [Float]
        if llama_pooling_type(ctx) == LLAMA_POOLING_TYPE_NONE {
            guard let p = llama_get_embeddings(ctx) else { throw CoreError.decode("no embeddings") }
            v = [Float](repeating: 0, count: nEmbd)
            for t in 0..<tokens.count { for j in 0..<nEmbd { v[j] += p[t * nEmbd + j] } }
            v = v.map { $0 / Float(tokens.count) }
        } else {
            guard let p = llama_get_embeddings_seq(ctx, 0) else { throw CoreError.decode("no pooled embedding") }
            v = Array(UnsafeBufferPointer(start: p, count: nEmbd))
        }
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        return norm > 0 ? v.map { $0 / norm } : v
    }
}

import Foundation
import llama

/// What one generation cost. Field names and meanings match harness/run_calendar.py LocalModel.
struct GenInfo {
    var firstTokenMs: Double?
    var totalMs: Double
    var inputTokens: Int        // the whole prompt, as in the Mac harness
    var cachedTokens: Int       // of those, reused from the previous request (shared system prompt)
    var outputTokens: Int
    var decodeTokS: Double?
    var timedOut: Bool
    var hitMaxTokens: Bool
    var finishReason: String?
}

enum EngineError: LocalizedError {
    case load(String), context, decode(Int32), tokenize, grammar
    var errorDescription: String? {
        switch self {
        case .load(let p): return "Could not load the model at \(p)"
        case .context: return "Could not create the llama.cpp context"
        case .decode(let c): return "llama_decode failed (\(c))"
        case .tokenize: return "Tokenization failed"
        case .grammar: return "The GBNF grammar did not parse"
        }
    }
}

/// llama.cpp in-process (Metal on a device, CPU in the Simulator). Not thread-safe: the
/// ModelService actor owns it. Mirrors llama-cpp-python 0.3.37 as the Mac harness calls it:
/// temperature 0 (penalties off -> grammar -> greedy), n_ctx 4096, n_batch 512, flash attention
/// off, and the longest common prefix with the previous request kept in the KV cache.
final class LlamaEngine {
    private let model: OpaquePointer
    private let ctx: OpaquePointer
    private let vocab: OpaquePointer
    private var cached: [llama_token] = []  // tokens currently in the KV cache
    let nBatch: Int32 = 512
    let loadMs: Double

    init(path: String, mmap: Bool, gpu: Bool = true) throws {
        let t0 = CFAbsoluteTimeGetCurrent()
        llama_backend_init()
        var mp = llama_model_default_params()
        mp.n_gpu_layers = gpu ? -1 : 0  // -1: every layer on the GPU (Metal)
        mp.load_mode = mmap ? LLAMA_LOAD_MODE_MMAP : LLAMA_LOAD_MODE_NONE
        guard let m = llama_model_load_from_file(path, mp) else { throw EngineError.load(path) }
        var cp = llama_context_default_params()
        cp.n_ctx = 4096
        cp.n_batch = UInt32(nBatch)
        cp.n_ubatch = UInt32(nBatch)
        cp.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_DISABLED
        let cores = Int32(max(1, ProcessInfo.processInfo.activeProcessorCount / 2))  // llama-cpp-python's default
        cp.n_threads = cores
        cp.n_threads_batch = cores
        guard let c = llama_init_from_model(m, cp) else { llama_model_free(m); throw EngineError.context }
        model = m
        ctx = c
        vocab = llama_model_get_vocab(m)
        loadMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
    }

    deinit {
        llama_free(ctx)
        llama_model_free(model)
    }

    func tokenize(_ text: String) throws -> [llama_token] {
        let utf8 = Array(text.utf8CString.dropLast())  // no NUL
        var toks = [llama_token](repeating: 0, count: utf8.count + 8)
        // add_special=false (the chat template already starts with <|begin_of_text|>), parse_special=true
        let n = utf8.withUnsafeBufferPointer { b in
            llama_tokenize(vocab, b.baseAddress, Int32(utf8.count), &toks, Int32(toks.count), false, true)
        }
        guard n >= 0 else { throw EngineError.tokenize }
        return Array(toks.prefix(Int(n)))
    }

    private func piece(_ t: llama_token) -> [UInt8] {
        var buf = [CChar](repeating: 0, count: 64)
        var n = llama_token_to_piece(vocab, t, &buf, Int32(buf.count), 0, false)
        if n < 0 {
            buf = [CChar](repeating: 0, count: Int(-n))
            n = llama_token_to_piece(vocab, t, &buf, Int32(buf.count), 0, false)
        }
        return buf.prefix(Int(max(0, n))).map { UInt8(bitPattern: $0) }
    }

    private func decode(_ toks: [llama_token]) throws {
        var start = 0
        while start < toks.count {
            var chunk = Array(toks[start..<min(toks.count, start + Int(nBatch))])
            let rc = chunk.withUnsafeMutableBufferPointer { llama_decode(ctx, llama_batch_get_one($0.baseAddress, Int32($0.count))) }
            guard rc == 0 else { cached = []; throw EngineError.decode(rc) }
            cached += chunk
            start += chunk.count
        }
    }

    // MARK: fast decoding (same output as greedy + grammar)

    /// Lazy grammar (as llama.cpp's common sampler): take the greedy token from the raw logits and
    /// check only that one token against the grammar; only if it is not allowed, mask the whole
    /// vocabulary. The result equals greedy-after-grammar, at a fraction of the grammar cost.
    var lazyGrammar = true
    /// Prompt-lookup decoding (Saxena 2023; speculative decoding with an n-gram draft): propose up
    /// to this many next tokens by copying what followed the last n tokens earlier in the context,
    /// and verify them in one batch. Greedy verification keeps the output unchanged. 0 = off.
    var lookupDraft = 0   // measured 2026-11-27: off (Mac: no reliable gain; batch verification changed 3/60 outputs via rounding)

    private func argmaxToken(_ logits: UnsafeMutablePointer<Float>, _ n: Int) -> llama_token {
        var best = 0
        var bv = logits[0]
        for i in 1..<n where logits[i] > bv { bv = logits[i]; best = i }
        return llama_token(best)
    }

    /// Greedy choice at batch index `idx`, under the grammar if there is one (and accepted into it).
    private func choose(_ idx: Int32, grammar: UnsafeMutablePointer<llama_sampler>?, scratch: inout [llama_token_data]) -> llama_token {
        let n = Int(llama_vocab_n_tokens(vocab))
        let logits = llama_get_logits_ith(ctx, idx)!
        guard let grammar else { return argmaxToken(logits, n) }
        if lazyGrammar {
            let tok = argmaxToken(logits, n)
            var one = llama_token_data(id: tok, logit: logits[Int(tok)], p: 0)
            let ok: Bool = withUnsafeMutablePointer(to: &one) { ptr in
                var arr = llama_token_data_array(data: ptr, size: 1, selected: -1, sorted: false)
                llama_sampler_apply(grammar, &arr)
                return arr.data[0].logit.isFinite
            }
            if ok { llama_sampler_accept(grammar, tok); return tok }
        }
        if scratch.count != n { scratch = (0..<n).map { llama_token_data(id: llama_token($0), logit: 0, p: 0) } }
        for i in 0..<n { scratch[i].id = llama_token(i); scratch[i].logit = logits[i]; scratch[i].p = 0 }
        let tok: llama_token = scratch.withUnsafeMutableBufferPointer { buf in
            var arr = llama_token_data_array(data: buf.baseAddress, size: n, selected: -1, sorted: false)
            llama_sampler_apply(grammar, &arr)
            var best = 0
            var bv = -Float.infinity
            for i in 0..<n where buf[i].logit > bv { bv = buf[i].logit; best = i }
            return buf[best].id
        }
        llama_sampler_accept(grammar, tok)
        return tok
    }

    /// Up to k tokens that followed the most recent earlier occurrence of the last 3 (or 2, 1) tokens.
    private func lookup(_ ctxToks: [llama_token], _ k: Int) -> [llama_token] {
        guard k > 0 else { return [] }
        for n in stride(from: 3, through: 1, by: -1) where ctxToks.count > n {
            let key = Array(ctxToks.suffix(n))
            var s = ctxToks.count - n - 1
            while s >= 0 {
                if Array(ctxToks[s..<(s + n)]) == key {
                    let start = s + n
                    return Array(ctxToks[start..<min(ctxToks.count, start + k)])
                }
                s -= 1
            }
        }
        return []
    }

    /// Greedy (+ grammar) generation with lazy grammar and prompt-lookup verification. Same output
    /// as `generate`; fewer forward passes and cheaper grammar checks.
    func generateFast(prompt: String, grammar: String?, maxTokens: Int, timeoutS: Double,
                      onText: ((String) -> Void)? = nil) throws -> (String, GenInfo, Int) {
        let t0 = CFAbsoluteTimeGetCurrent()
        let toks = try tokenize(prompt)
        let prefix = zip(cached, toks.dropLast()).prefix(while: { $0 == $1 }).count
        _ = llama_memory_seq_rm(llama_get_memory(ctx), -1, Int32(prefix), -1)
        cached = Array(cached.prefix(prefix))
        try decode(Array(toks[prefix...]))   // logits of the last prompt token are at batch index -1

        var gsampler: UnsafeMutablePointer<llama_sampler>? = nil
        if let grammar {
            guard let g = llama_sampler_init_grammar(vocab, grammar, "root") else { throw EngineError.grammar }
            gsampler = g
        }
        defer { if let gsampler { llama_sampler_free(gsampler) } }
        var scratch: [llama_token_data] = []
        var batch = llama_batch_init(Int32(lookupDraft + 1), 0, 1)
        defer { llama_batch_free(batch) }

        var bytes: [UInt8] = []
        var out: [llama_token] = []
        var tFirst: CFAbsoluteTime? = nil, timedOut = false, passes = 0
        var finish: String? = "length"
        var cur = choose(-1, grammar: gsampler, scratch: &scratch)
        func emit(_ t: llama_token) {
            out.append(t)
            let p = piece(t)
            if !p.isEmpty {
                if tFirst == nil { tFirst = CFAbsoluteTimeGetCurrent() }
                bytes += p
                onText?(String(decoding: bytes, as: UTF8.self))
            }
        }
        loop: while true {
            if llama_vocab_is_eog(vocab, cur) { finish = "stop"; break }
            emit(cur)
            if out.count >= maxTokens { break }
            if CFAbsoluteTimeGetCurrent() - t0 > timeoutS { timedOut = true; finish = nil; break }
            // Decode cur plus a copied draft in one pass; every position gets logits.
            let draft = lookup(cached + [cur], min(lookupDraft, maxTokens - out.count))
            let seq = [cur] + draft
            let base = Int32(cached.count)
            batch.n_tokens = Int32(seq.count)
            for (j, t) in seq.enumerated() {
                batch.token[j] = t
                batch.pos[j] = base + Int32(j)
                batch.n_seq_id[j] = 1
                batch.seq_id[j]![0] = 0
                batch.logits[j] = 1
            }
            let rc = llama_decode(ctx, batch)
            guard rc == 0 else { cached = []; throw EngineError.decode(rc) }
            passes += 1
            cached += seq
            var accepted = 0
            for j in 0..<seq.count {
                let next = choose(Int32(j), grammar: gsampler, scratch: &scratch)
                if j < draft.count, next == draft[j], !llama_vocab_is_eog(vocab, next) {
                    accepted += 1
                    emit(next)
                    if out.count >= maxTokens { break loop }
                    continue
                }
                cur = next
                break
            }
            // Drop the rejected part of the draft from the KV cache.
            let keep = Int(base) + 1 + accepted
            if keep < cached.count {
                _ = llama_memory_seq_rm(llama_get_memory(ctx), -1, Int32(keep), -1)
                cached = Array(cached.prefix(keep))
            }
        }
        let tEnd = CFAbsoluteTimeGetCurrent()
        let nOut = out.count
        let decodeS = tFirst.map { tEnd - $0 } ?? 0
        let info = GenInfo(
            firstTokenMs: tFirst.map { (($0 - t0) * 1000 * 10).rounded() / 10 },
            totalMs: ((tEnd - t0) * 1000 * 10).rounded() / 10,
            inputTokens: toks.count, cachedTokens: prefix, outputTokens: nOut,
            decodeTokS: decodeS > 0 && nOut > 1 ? ((Double(nOut - 1) / decodeS) * 10).rounded() / 10 : nil,
            timedOut: timedOut, hitMaxTokens: finish == "length", finishReason: finish)
        return (String(decoding: bytes, as: UTF8.self), info, passes)
    }

    /// Generate from a fully formatted prompt. `onText` gets the text so far after each token.
    func generate(prompt: String, grammar: String?, maxTokens: Int, timeoutS: Double,
                  onText: ((String) -> Void)? = nil) throws -> (String, GenInfo) {
        let t0 = CFAbsoluteTimeGetCurrent()
        let toks = try tokenize(prompt)

        // Keep the longest prefix shared with what is already in the cache (at least the last
        // prompt token is always evaluated, as in llama-cpp-python).
        let prefix = zip(cached, toks.dropLast()).prefix(while: { $0 == $1 }).count
        _ = llama_memory_seq_rm(llama_get_memory(ctx), -1, Int32(prefix), -1)
        cached = Array(cached.prefix(prefix))
        try decode(Array(toks[prefix...]))

        let chain = llama_sampler_chain_init(llama_sampler_chain_default_params())!
        defer { llama_sampler_free(chain) }
        if let grammar {
            guard let g = llama_sampler_init_grammar(vocab, grammar, "root") else { throw EngineError.grammar }
            llama_sampler_chain_add(chain, g)
        }
        llama_sampler_chain_add(chain, llama_sampler_init_greedy())

        var bytes: [UInt8] = []
        var nOut = 0, tFirst: CFAbsoluteTime? = nil, timedOut = false
        var finish: String? = "length"  // nil on timeout, as in the Mac harness
        while nOut < maxTokens {
            let tok = llama_sampler_sample(chain, ctx, -1)  // also accepts the token into the grammar
            if llama_vocab_is_eog(vocab, tok) { finish = "stop"; break }
            nOut += 1
            let p = piece(tok)
            if !p.isEmpty {
                if tFirst == nil { tFirst = CFAbsoluteTimeGetCurrent() }
                bytes += p
                onText?(String(decoding: bytes, as: UTF8.self))
            }
            if CFAbsoluteTimeGetCurrent() - t0 > timeoutS { timedOut = true; finish = nil; break }
            if nOut < maxTokens { try decode([tok]) }  // the token sampled at the cap is never evaluated
        }
        let tEnd = CFAbsoluteTimeGetCurrent()
        let decodeS = tFirst.map { tEnd - $0 } ?? 0
        let info = GenInfo(
            firstTokenMs: tFirst.map { (($0 - t0) * 1000 * 10).rounded() / 10 },
            totalMs: ((tEnd - t0) * 1000 * 10).rounded() / 10,
            inputTokens: toks.count, cachedTokens: prefix, outputTokens: nOut,
            decodeTokS: decodeS > 0 && nOut > 1 ? ((Double(nOut - 1) / decodeS) * 10).rounded() / 10 : nil,
            timedOut: timedOut, hitMaxTokens: finish == "length", finishReason: finish)
        return (String(decoding: bytes, as: UTF8.self), info)
    }
}

import Foundation
import SQLite3

public struct Hit {
    public let noteID: String
    public let score: Double
    public let title: String
    public let body: String
}

public protocol Retriever {
    func search(_ question: String, k: Int) -> [Hit]
}

/// Same stop words and query rules as harness/retrieval.py.
public enum Query {
    static let stopwords: Set<String> = Set("""
    a an and are at be did do does for from had has have how i i'm in is it its me my of on or
    should the to was what what's when where which who who's whom why will with you your
    """.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init))

    public static func terms(_ question: String) -> [String] {
        let lower = question.lowercased()
        let re = try! NSRegularExpression(pattern: "[a-z0-9]+(?:'[a-z]+)?")
        var out: [String] = []
        for m in re.matches(in: lower, range: NSRange(lower.startIndex..., in: lower)) {
            let w = String(lower[Range(m.range, in: lower)!]).split(separator: "'", omittingEmptySubsequences: false)[0]
            let word = String(w)
            if !word.isEmpty, !stopwords.contains(word), !out.contains(word) { out.append(word) }
        }
        return out
    }
}

/// BM25 over SQLite FTS5 (tokenizer "porter unicode61"), like BM25Index in harness/retrieval.py.
public final class BM25Index: Retriever {
    private var db: OpaquePointer?
    public let notes: [String: Note]
    private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(notes: [Note]) throws {
        self.notes = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0) })
        guard sqlite3_open(":memory:", &db) == SQLITE_OK else { throw CoreError.sqlite("open") }
        try exec("CREATE VIRTUAL TABLE notes USING fts5(id UNINDEXED, title, body, tokenize='porter unicode61')")
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO notes VALUES (?, ?, ?)", -1, &stmt, nil) == SQLITE_OK else {
            throw CoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        for n in notes {
            sqlite3_bind_text(stmt, 1, n.id, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, n.title, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, n.body, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw CoreError.sqlite(String(cString: sqlite3_errmsg(db))) }
            sqlite3_reset(stmt)
        }
    }

    deinit { sqlite3_close(db) }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw CoreError.sqlite(String(cString: sqlite3_errmsg(db)))  // e.g. "no such module: fts5"
        }
    }

    public func search(_ question: String, k: Int) -> [Hit] {
        let t = Query.terms(question)
        if t.isEmpty { return [] }
        let match = t.map { "\"\($0)\"" }.joined(separator: " OR ")
        let sql = "SELECT id, -bm25(notes) AS score, title, body FROM notes WHERE notes MATCH ? ORDER BY score DESC, id LIMIT ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, match, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(k))
        var hits: [Hit] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            hits.append(Hit(noteID: String(cString: sqlite3_column_text(stmt, 0)), score: sqlite3_column_double(stmt, 1),
                            title: String(cString: sqlite3_column_text(stmt, 2)), body: String(cString: sqlite3_column_text(stmt, 3))))
        }
        return hits
    }
}

/// Dense retrieval with a GGUF embedding model, like DenseIndex in harness/retrieval.py.
public final class DenseIndex: Retriever {
    let embedder: Embedder
    let ids: [String]
    let notes: [String: Note]
    let queryPrefix: String
    var docVecs: [[Float]] = []

    public init(notes: [Note], embedder: Embedder, queryPrefix: String, docPrefix: String) throws {
        self.embedder = embedder
        self.ids = notes.map(\.id)
        self.notes = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0) })
        self.queryPrefix = queryPrefix
        docVecs = try notes.map { try embedder.embed(docPrefix + "\($0.title). \($0.body)") }
    }

    public func search(_ question: String, k: Int) -> [Hit] {
        guard let q = try? embedder.embed(queryPrefix + question) else { return [] }
        let scored = zip(ids, docVecs).map { (id, d) -> (Double, String) in
            (Double(zip(q, d).reduce(Float(0)) { $0 + $1.0 * $1.1 }), id)
        }.sorted { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1 < $1.1 }
        return scored.prefix(k).map { Hit(noteID: $0.1, score: $0.0, title: notes[$0.1]!.title, body: notes[$0.1]!.body) }
    }
}

/// Reciprocal rank fusion of BM25 and dense rankings, like HybridIndex in harness/retrieval.py.
public final class HybridIndex: Retriever {
    let bm25: BM25Index
    let dense: DenseIndex
    let rrfK: Int
    let candidates: Int

    public init(bm25: BM25Index, dense: DenseIndex, rrfK: Int = 60, candidates: Int = 10) {
        self.bm25 = bm25; self.dense = dense; self.rrfK = rrfK; self.candidates = candidates
    }

    public func search(_ question: String, k: Int) -> [Hit] {
        var fused: [String: Double] = [:]
        for ranking in [bm25.search(question, k: candidates), dense.search(question, k: candidates)] {
            for (rank, h) in ranking.enumerated() {
                fused[h.noteID, default: 0] += 1.0 / Double(rrfK + rank + 1)
            }
        }
        let top = fused.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(k)
        return top.map { Hit(noteID: $0.key, score: $0.value, title: bm25.notes[$0.key]!.title, body: bm25.notes[$0.key]!.body) }
    }
}

public enum CoreError: Error, CustomStringConvertible {
    case sqlite(String), model(String), decode(String), spec(String)
    public var description: String {
        switch self {
        case .sqlite(let m): return "SQLite: \(m)"
        case .model(let m): return "model: \(m)"
        case .decode(let m): return "decode: \(m)"
        case .spec(let m): return "spec: \(m)"
        }
    }
}

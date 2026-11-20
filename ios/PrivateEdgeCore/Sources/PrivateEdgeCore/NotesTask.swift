import Foundation

public struct Note: Codable {
    public let id: String
    public let title: String
    public let body: String
}

public struct NotesItem {
    public let id: String
    public let question: String
    public let referenceTime: String
    public let support: [String]
    public let raw: [String: Any]

    public init?(_ obj: [String: Any]) {
        guard let id = obj["id"] as? String, let q = obj["question"] as? String,
              let ref = obj["reference_time"] as? String else { return nil }
        self.id = id
        question = q
        referenceTime = ref
        support = ((obj["gold"] as? [String: Any])?["support"] as? [String]) ?? []
        raw = obj
    }
}

public struct Citation: Codable, Equatable {
    public let note_id: String
    public let quote: String
}

/// Mirrors harness/run_notes.py: the user message, output parsing and abstain rule.
public enum NotesTask {
    public static let abstainText = "the notes don't say"

    public static func formatNotes(_ hits: [Hit]) -> String {
        hits.map { "[\($0.noteID)] \($0.title)\n\($0.body)" }.joined(separator: "\n\n")
    }

    /// "Today is Monday, 2 November 2026, 10:00.\n\nNotes:\n\n...\n\nQuestion: ..."
    public static func userMessage(question: String, ref: ReferenceTime, hits: [Hit]) -> String {
        let today = "\(ref.format("EEEE")), \(ref.format("d")) \(ref.format("MMMM yyyy")), \(ref.format("HH:mm"))"
        return "Today is \(today).\n\nNotes:\n\n\(formatNotes(hits))\n\nQuestion: \(question)"
    }

    /// Returns (answer, citations, formatOK), like parse_output in run_notes.py.
    public static func parseOutput(_ text: String) -> (String, [Citation], Bool) {
        var s = text.pyStrip()
        s = s.replacingOccurrences(of: #"^```(?:json)?\s*"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s*```$"#, with: "", options: .regularExpression)
        guard let start = s.firstIndex(of: "{"), let end = s.lastIndex(of: "}"), start <= end,
              let data = String(s[start...end]).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answer = obj["answer"] as? String
        else { return (text.pyStrip(), [], false) }
        let rawCits = obj["citations"] as? [Any] ?? (obj["citations"] == nil || obj["citations"] is NSNull ? [] : nil)
        var ok = rawCits != nil
        var cits: [Citation] = []
        for c in rawCits ?? [] {
            guard let d = c as? [String: Any], let nid = d["note_id"], let q = d["quote"] else { ok = false; continue }
            cits.append(Citation(note_id: "\(nid)", quote: "\(q)"))
        }
        return (answer.pyStrip(), cits, ok)
    }

    public static func isAbstain(_ answer: String) -> Bool {
        var a = answer.pyStrip().lowercased()
        while a.hasSuffix(".") { a.removeLast() }
        return a == abstainText
    }
}

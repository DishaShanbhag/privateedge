import Foundation

/// An item's fixed reference time, e.g. "2026-11-02T10:00:00-05:00", kept in its own UTC offset.
public struct ReferenceTime {
    public let date: Date
    public let timeZone: TimeZone

    public init?(iso: String) {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        guard let d = f.date(from: iso), iso.count >= 6 else { return nil }
        // Offset is the trailing "+HH:MM" / "-HH:MM" (or "Z").
        let tail = String(iso.suffix(6))
        var seconds = 0
        if let sign = tail.first, sign == "+" || sign == "-" {
            let parts = tail.dropFirst().split(separator: ":")
            guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
            seconds = (sign == "-" ? -1 : 1) * (h * 3600 + m * 60)
        }
        guard let tz = TimeZone(secondsFromGMT: seconds) else { return nil }
        date = d
        timeZone = tz
    }

    public func format(_ pattern: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = pattern
        return f.string(from: date)
    }
}

/// Renders the Llama 3.2 chat prompt exactly like harness/chat_prompt.py:render_llama32
/// (the GGUF's template with "Today Date" pinned to the item's reference date).
public enum ChatPrompt {
    /// strftime("%d %b %Y"), e.g. "02 Nov 2026".
    public static func dateString(_ ref: ReferenceTime) -> String { ref.format("dd MMM yyyy") }

    public static func renderLlama32(system: String, user: String, ref: ReferenceTime) -> String {
        "<|begin_of_text|><|start_header_id|>system<|end_header_id|>\n\n"
            + "Cutting Knowledge Date: December 2023\n"
            + "Today Date: \(dateString(ref))\n\n"
            + "\(system.pyStrip())<|eot_id|>"
            + "<|start_header_id|>user<|end_header_id|>\n\n\(user.pyStrip())<|eot_id|>"
            + "<|start_header_id|>assistant<|end_header_id|>\n\n"
    }
}

extension String {
    /// Python's str.strip() for ASCII whitespace.
    func pyStrip() -> String { trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\r\u{0B}\u{0C}")) }
}

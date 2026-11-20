import Foundation

/// The Llama 3.2 chat template from the GGUF file (system + user, no tools, generation prompt on),
/// as harness/chat_prompt.py render_llama32 renders it: "Today Date" is the item's reference date
/// (`templateDate(item)`), not the machine's date the built-in template would stamp (CHANGELOG
/// 2026-11-19).
public func chatPrompt(system: String, user: String, today: String) -> String {
    "<|begin_of_text|><|start_header_id|>system<|end_header_id|>\n\n"
        + "Cutting Knowledge Date: December 2023\nToday Date: \(today)\n\n"
        + system.pyStrip() + "<|eot_id|>"
        + "<|start_header_id|>user<|end_header_id|>\n\n" + user.pyStrip() + "<|eot_id|>"
        + "<|start_header_id|>assistant<|end_header_id|>\n\n"
}

/// The template's date for an item: its reference date in its own zone, as "%d %b %Y".
public func templateDate(_ item: Item) -> String {
    let d = localRef(item.referenceTime, item.tz).day
    let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    return String(format: "%02d %@ %04d", d.d, months[d.m - 1], d.y)
}

/// strftime("%d %b %Y") in the device's time zone, e.g. "19 Nov 2026".
public func llamaToday(_ now: Date = Date()) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "dd MMM yyyy"
    return f.string(from: now)
}

/// The repair note of run_calendar.py (C3_repair ablation).
public let REPAIR_NOTE = "Your previous answer failed a check: {why}. Reply again with one corrected JSON object, "
    + "or clarify if the message does not say."

/// What the app asks the user for each clarify field.
public func clarifyQuestion(_ field: String) -> String {
    switch field {
    case "date": return "Which day?"
    case "start_time": return "What time does it start?"
    case "ampm": return "Is that AM or PM?"
    case "which_event": return "Which one do you mean? The message mentions more than one."
    case "conflict": return "Some details don't match. Can you check them?"
    case "invalid_time": return "That date or time doesn't exist. Which one did you mean?"
    case "amount": return "How much was it?"
    default: return "Can you say more?"
    }
}

import Foundation

/// The Llama 3.2 chat template from the GGUF file, as llama-cpp-python renders it for the Mac
/// harness (system + user, no tools, generation prompt on). The template stamps "Today Date" with
/// the run machine's current date (strftime_now "%d %b %Y"), so pass the same string to match a
/// Mac run, or `llamaToday()` to behave as the Mac harness would today.
public func chatPrompt(system: String, user: String, today: String) -> String {
    "<|begin_of_text|><|start_header_id|>system<|end_header_id|>\n\n"
        + "Cutting Knowledge Date: December 2023\nToday Date: \(today)\n\n"
        + system.pyStrip() + "<|eot_id|>"
        + "<|start_header_id|>user<|end_header_id|>\n\n" + user.pyStrip() + "<|eot_id|>"
        + "<|start_header_id|>assistant<|end_header_id|>\n\n"
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

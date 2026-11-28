import CalendarCore
import EventKit
import SwiftUI

/// The calendar screen: type a message, get one action (or a question), all on the phone.
struct CalendarView: View {
    @EnvironmentObject var app: AppModel
    @State private var message = ""
    @State private var config: LadderConfig = .C3_code
    @State private var streaming = ""
    @State private var result: RunResult?
    @State private var running = false
    @State private var error: String?
    @State private var saved: String?

    private let examples = ["dinner with Sam friday at 7", "remind me to pay rent tomorrow",
                            "paid $12.50 for lunch yesterday", "call at 7", "thanks, see you then!"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Type a message…", text: $message, axis: .vertical)
                        .lineLimit(1...4)
                        .submitLabel(.go)
                        .onSubmit(run)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(examples, id: \.self) { ex in
                                Button(ex) { message = ex }
                                    .buttonStyle(.bordered).controlSize(.small)
                            }
                        }
                    }
                    Picker("Pipeline", selection: $config) {
                        ForEach([LadderConfig.C0, .C1, .C3, .C3_code], id: \.self) { Text($0 == .C3_code ? "C3+code" : $0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Button(action: run) {
                        HStack {
                            if running { ProgressView().padding(.trailing, 4) }
                            Text(running ? "Thinking on device…" : "Run")
                        }.frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(running || message.trimmingCharacters(in: .whitespaces).isEmpty || !ready)
                } footer: {
                    if !ready { ModelStatusLine() }
                }

                if running || result != nil {
                    Section("Model output") {
                        Text(result?.raw ?? streaming)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                if let result {
                    Section("Result") { ActionCard(result: result, saved: $saved) }
                    if result.config.verify { Section("Verification (C3)") { VerifierView(result: result) } }
                    Section("On-device cost") { MetricsView(result: result) }
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle("PrivateEdge")
        }
    }

    private var ready: Bool { if case .ready = app.state { return true }; return false }

    private func run() {
        guard ready, !running else { return }
        let item = nowItem(message.trimmingCharacters(in: .whitespacesAndNewlines))
        running = true; result = nil; error = nil; streaming = ""; saved = nil
        let cfg = config
        Task {
            do {
                let r = try await app.service.run(item, cfg, today: templateDate(item)) { text in
                    Task { @MainActor in streaming = text }
                }
                result = r
            } catch {
                self.error = error.localizedDescription
            }
            running = false
        }
    }
}

struct ModelStatusLine: View {
    @EnvironmentObject var app: AppModel
    var body: some View {
        switch app.state {
        case .missing: Text("Model file not found. See the Model tab.").foregroundStyle(.orange)
        case .idle: Text("Model not loaded. See the Model tab.")
        case .loading: HStack { ProgressView(); Text("Loading the model…") }
        case .ready(let ms): Text(String(format: "Model loaded in %.1f s", ms / 1000))
        case .failed(let e): Text(e).foregroundStyle(.red)
        }
    }
}

// MARK: - Result card

struct ActionCard: View {
    let result: RunResult
    @Binding var saved: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch result.final {
            case .event(let e)?:
                Label(e.title, systemImage: "calendar").font(.headline)
                Text(when(e.start, minutes: e.durationMin))
                Button("Add to Calendar") { addEvent(e) }.buttonStyle(.bordered)
            case .reminder(let r)?:
                Label(r.title, systemImage: "bell").font(.headline)
                Text(when(r.start, minutes: nil))
                Button("Add to Reminders") { addReminder(r) }.buttonStyle(.bordered)
            case .expense(let x)?:
                Label("\(x.currency) \(x.amount)", systemImage: "creditcard").font(.headline)
                Text("\(x.description) · \(x.date.description)")
            case .none?:
                Label("No action needed", systemImage: "checkmark.circle")
            case .clarify(let fields)?:
                Label("Needs your answer", systemImage: "questionmark.bubble").font(.headline)
                ForEach(fields, id: \.self) { Text(clarifyQuestion($0)) }
            case nil:
                Label("The model's answer was not valid (\(result.parseError ?? "?"))", systemImage: "xmark.octagon")
                    .foregroundStyle(.red)
            }
            if let saved { Text(saved).font(.footnote).foregroundStyle(.secondary) }
        }
    }

    private func date(_ z: ZDT) -> Date { Date(timeIntervalSince1970: TimeInterval(z.epoch)) }

    private func when(_ z: ZDT, minutes: Int?) -> String {
        let f = DateFormatter()
        f.timeZone = TimeZone(secondsFromGMT: z.offset)
        f.dateFormat = "EEE d MMM yyyy · h:mm a"
        var s = f.string(from: date(z))
        if let minutes {
            f.dateFormat = "h:mm a"
            s += " – " + f.string(from: date(z).addingTimeInterval(TimeInterval(minutes * 60))) + " (\(minutes) min)"
        }
        return s + " · UTC" + String(z.iso.suffix(6))
    }

    private func addEvent(_ e: Event) {
        let store = EKEventStore()
        store.requestWriteOnlyAccessToEvents { ok, _ in
            guard ok else { Task { @MainActor in saved = "Calendar access was not allowed." }; return }
            let ev = EKEvent(eventStore: store)
            ev.title = e.title
            ev.startDate = date(e.start)
            ev.endDate = date(e.start).addingTimeInterval(TimeInterval(e.durationMin * 60))
            ev.calendar = store.defaultCalendarForNewEvents
            let msg = (try? store.save(ev, span: .thisEvent)) != nil ? "Added to Calendar." : "Could not save the event."
            Task { @MainActor in saved = msg }
        }
    }

    private func addReminder(_ r: Reminder) {
        let store = EKEventStore()
        store.requestFullAccessToReminders { ok, _ in
            guard ok else { Task { @MainActor in saved = "Reminders access was not allowed." }; return }
            let rem = EKReminder(eventStore: store)
            rem.title = r.title
            rem.calendar = store.defaultCalendarForNewReminders()
            let d = date(r.start)
            rem.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: d)
            rem.addAlarm(EKAlarm(absoluteDate: d))
            let msg = (try? store.save(rem, commit: true)) != nil ? "Added to Reminders." : "Could not save the reminder."
            Task { @MainActor in saved = msg }
        }
    }
}

struct VerifierView: View {
    let result: RunResult
    var body: some View {
        if let v = result.verdict {
            if v.ok {
                Label("All checks passed: the dates, times and title match the message.", systemImage: "checkmark.shield")
                    .foregroundStyle(.green)
            } else {
                Label("Check failed: \(v.failed.joined(separator: ", ")). Asking instead of guessing.", systemImage: "exclamationmark.shield")
                    .foregroundStyle(.orange)
                ForEach(v.details.keys.sorted(), id: \.self) { k in
                    Text("\(k): \(v.details[k]!)").font(.footnote).foregroundStyle(.secondary)
                }
            }
            if !v.replaced.isEmpty {
                Label("Code computed the \(v.replaced.joined(separator: ", ")) from your words; the model's value was different.",
                      systemImage: "function").font(.footnote)
            }
            if let b = result.before, b != result.final {
                Text("Model said: \(b.kind); shown: \(result.final?.kind ?? "-")").font(.footnote)
            }
        } else {
            Text(result.final == nil ? "Not checked: the output was not valid." : "Nothing to check for \(result.final!.kind).")
                .font(.footnote)
        }
    }
}

struct MetricsView: View {
    let result: RunResult
    var body: some View {
        let i = result.info, d = result.device.json
        Grid(alignment: .leading, verticalSpacing: 4) {
            row("First token", i.firstTokenMs.map { String(format: "%.0f ms", $0) } ?? "-")
            row("Total", String(format: "%.2f s", i.totalMs / 1000))
            row("Tokens in / cached / out", "\(i.inputTokens) / \(i.cachedTokens) / \(i.outputTokens)")
            row("Decode speed", i.decodeTokS.map { String(format: "%.1f tok/s", $0) } ?? "-")
            if let v = result.verifyMs { row("Verification", String(format: "%.2f ms", v)) }
            row("Peak memory", num(d["peak_footprint_mb"]).map { String(format: "%.0f MB", $0) } ?? "-")
            row("Thermal", "\(d["thermal_state_before"]?.asString ?? "?") → \(d["thermal_state_after"]?.asString ?? "?")")
            row("Network", "none (runs fully on device)")
        }
        .font(.footnote)
    }
    private func row(_ k: String, _ v: String) -> some View {
        GridRow { Text(k).foregroundStyle(.secondary); Text(v) }
    }
}

func num(_ v: JV?) -> Double? {
    switch v {
    case .float(let d)?: return d
    case .int(let n)?: return Double(n)
    default: return nil
    }
}

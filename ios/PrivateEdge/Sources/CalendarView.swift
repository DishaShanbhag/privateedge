import CalendarCore
import EventKit
import SwiftUI

/// One exchange on the Calendar screen.
struct CalendarTurn: Identifiable {
    let id = UUID()
    let shown: String        // what the user typed in this turn
    let message: String      // what the pipeline reads (earlier message + this answer, for follow-ups)
    var result: RunResult?
    var error: String?
    let started = Date()
}

/// The calendar screen: tell it about a plan, a reminder or money spent; it answers with one action,
/// or asks one question and lets you reply. Everything runs on the phone.
struct CalendarView: View {
    @EnvironmentObject var app: AppModel
    @AppStorage("calendarPipeline") private var pipeline = LadderConfig.C3_code.rawValue
    @State private var input = ""
    @State private var turns: [CalendarTurn] = []
    @State private var partial = ""
    @State private var running = false
    @State private var showSettings = false

    private let examples = ["Dinner with Sam Friday at 7", "Remind me to pay rent tomorrow",
                            "Paid $12.50 for lunch yesterday", "Call at 7"]

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        PrivacyPill()
                        ModelBanner()
                        if turns.isEmpty {
                            intro
                        }
                        ForEach(turns) { turn in
                            UserBubble(text: turn.shown)
                            if let r = turn.result {
                                CalendarResultCard(result: r, isLatest: turn.id == turns.last?.id) { reply in
                                    send(reply, followUpOf: turn)
                                }
                            } else if let e = turn.error {
                                AnswerCard(icon: "xmark", color: .red, kind: "Something went wrong") { Text(e).font(.callout) }
                            } else {
                                ThinkingCard(started: turn.started, partial: partial)
                            }
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding()
                }
                .background(Color(.systemGroupedBackground))
                .onChange(of: turns.count) { withAnimation { proxy.scrollTo("bottom") } }
                .onChange(of: running) { withAnimation { proxy.scrollTo("bottom") } }
            }
            .safeAreaInset(edge: .bottom) {
                ChatInputBar(text: $input, placeholder: "A plan, a reminder, money spent…", busy: running, enabled: ready) {
                    send(input, followUpOf: nil)
                }
            }
            .navigationTitle("Calendar")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if !turns.isEmpty { Button("Clear conversation", systemImage: "trash") { turns = [] } }
                        Button("Pipeline settings", systemImage: "slider.horizontal.3") { showSettings = true }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .sheet(isPresented: $showSettings) { PipelineSettings(pipeline: $pipeline) }
            .onChange(of: ready) { if ready, let demo = demoArgument("-demoCalendar"), turns.isEmpty { send(demo, followUpOf: nil) } }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Tell me about a plan, a reminder or something you paid for. I'll turn it into one entry, or ask if something is missing.")
                .font(.callout).foregroundStyle(.secondary)
            ExampleChips(title: "Try one:", examples: examples) { send($0, followUpOf: nil) }
        }
    }

    private var ready: Bool { if case .ready = app.state { return true }; return false }

    private func send(_ text: String, followUpOf previous: CalendarTurn?) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ready, !running, !t.isEmpty else { return }
        input = ""
        // A reply to a question is read together with the message it answers ("call at 7" + "friday").
        let message = previous.map { "\($0.message) \(t)" } ?? t
        turns.append(CalendarTurn(shown: t, message: message))
        let idx = turns.count - 1
        running = true; partial = ""
        let cfg = LadderConfig(rawValue: pipeline) ?? .C3_code
        let item = nowItem(message)
        Task {
            do {
                turns[idx].result = try await app.service.run(item, cfg, today: templateDate(item)) { text in
                    Task { @MainActor in partial = text }
                }
            } catch {
                turns[idx].error = error.localizedDescription
            }
            running = false
        }
    }
}

/// Which pipeline the Calendar tab uses (research setting; C3+code is the recommended default).
struct PipelineSettings: View {
    @Binding var pipeline: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Picker("Calendar pipeline", selection: $pipeline) {
                    ForEach([LadderConfig.C0, .C1, .C3, .C3_code], id: \.self) { c in
                        VStack(alignment: .leading) {
                            Text(c == .C3_code ? "C3+code (recommended)" : c.rawValue)
                            Text(c.label).font(.caption).foregroundStyle(.secondary)
                        }.tag(c.rawValue)
                    }
                }
                .pickerStyle(.inline)
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

struct ModelStatusLine: View {
    @EnvironmentObject var app: AppModel
    var body: some View {
        switch app.state {
        case .missing: Text("Model file not found.").foregroundStyle(.orange)
        case .idle: Text("Model not loaded.")
        case .loading: HStack { ProgressView(); Text("Loading the model…") }
        case .ready(let ms): Text(String(format: "Model loaded in %.1f s", ms / 1000))
        case .failed(let e): Text(e).foregroundStyle(.red)
        }
    }
}

// MARK: - Result card

struct CalendarResultCard: View {
    let result: RunResult
    let isLatest: Bool
    let reply: (String) -> Void
    @State private var saved: String?
    @State private var answer = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            card
            badge
            DisclosureGroup("Details") {
                VStack(alignment: .leading, spacing: 10) {
                    Text(result.raw).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                    VerifierView(result: result)
                    MetricsView(result: result)
                }
                .padding(.top, 6)
            }
            .font(.caption)
            .tint(.secondary)
            .padding(.horizontal, 4)
        }
    }

    @ViewBuilder private var card: some View {
        switch result.final {
        case .event(let e)?:
            AnswerCard(icon: "calendar", color: .blue, kind: "Event") {
                Text(e.title.capitalizedFirst).font(.title3.weight(.semibold))
                Label(dayText(e.start), systemImage: "calendar").font(.callout)
                Label(timeText(e.start, minutes: e.durationMin), systemImage: "clock").font(.callout)
                actionButton("Add to Calendar", "calendar.badge.plus") { addEvent(e) }
            }
        case .reminder(let r)?:
            AnswerCard(icon: "bell.fill", color: .orange, kind: "Reminder") {
                Text(r.title.capitalizedFirst).font(.title3.weight(.semibold))
                Label("\(dayText(r.start)) at \(clock(r.start))", systemImage: "alarm").font(.callout)
                actionButton("Add to Reminders", "checklist") { addReminder(r) }
            }
        case .expense(let x)?:
            AnswerCard(icon: "creditcard.fill", color: .green, kind: "Expense") {
                Text(money(x.amount, x.currency)).font(.title2.weight(.bold))
                Text(x.description.capitalizedFirst).font(.callout)
                Label(dayText(x.date), systemImage: "calendar").font(.callout).foregroundStyle(.secondary)
            }
        case .none?:
            AnswerCard(icon: "checkmark", color: .gray, kind: "No action") {
                Text("Nothing to add. This message doesn't need an event, reminder or expense.").font(.callout)
            }
        case .clarify(let fields)?:
            AnswerCard(icon: "questionmark", color: .purple, kind: "Quick question") {
                ForEach(fields, id: \.self) { Text(clarifyQuestion($0)).font(.title3.weight(.semibold)) }
                Text("I'd rather ask than guess and put the wrong thing in your calendar.").font(.caption).foregroundStyle(.secondary)
                if isLatest {
                    HStack {
                        TextField("Your answer, e.g. Friday", text: $answer)
                            .textFieldStyle(.roundedBorder)
                            .submitLabel(.send)
                            .onSubmit(sendAnswer)
                        Button("Reply", action: sendAnswer).buttonStyle(.borderedProminent)
                            .disabled(answer.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        case nil:
            AnswerCard(icon: "exclamationmark", color: .red, kind: "Didn't understand") {
                Text("Sorry, I couldn't turn that into an entry. Try saying it another way.").font(.callout)
            }
        }
    }

    @ViewBuilder private var badge: some View {
        if let v = result.verdict, v.ok, result.final != nil, ["event", "reminder", "expense"].contains(result.final!.kind) {
            Label(v.replaced.isEmpty ? "Checked on your phone" : "Date and time worked out exactly by the app",
                  systemImage: "checkmark.seal.fill")
                .font(.caption).foregroundStyle(.green).padding(.horizontal, 4)
        }
        if let saved { Text(saved).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4) }
    }

    private func sendAnswer() {
        let a = answer.trimmingCharacters(in: .whitespaces)
        guard !a.isEmpty else { return }
        answer = ""
        reply(a)
    }

    private func actionButton(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: icon).frame(maxWidth: .infinity) }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
            .disabled(saved?.hasPrefix("Added") == true)
    }

    // MARK: formatting

    private func date(_ z: ZDT) -> Date { Date(timeIntervalSince1970: TimeInterval(z.epoch)) }

    private func formatter(_ pattern: String, _ z: ZDT) -> DateFormatter {
        let f = DateFormatter()
        f.timeZone = TimeZone(secondsFromGMT: z.offset)
        f.setLocalizedDateFormatFromTemplate(pattern)
        return f
    }

    private func dayText(_ z: ZDT) -> String { formatter("EEEdMMM", z).string(from: date(z)) }
    private func dayText(_ d: Day) -> String {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.setLocalizedDateFormatFromTemplate("EEEdMMM")
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(d.ordinal * 86400 + 43200)))
    }
    private func clock(_ z: ZDT) -> String { formatter("jmm", z).string(from: date(z)) }

    private func timeText(_ z: ZDT, minutes: Int) -> String {
        let end = formatter("jmm", z).string(from: date(z).addingTimeInterval(TimeInterval(minutes * 60)))
        let dur = minutes % 60 == 0 ? "\(minutes / 60) h" : (minutes > 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min")
        var s = "\(clock(z)) – \(end) · \(dur)"
        if z.offset != TimeZone.current.secondsFromGMT(for: date(z)) { s += " (UTC" + String(z.iso.suffix(6)) + ")" }
        return s
    }

    private func money(_ amount: String, _ currency: String) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currency
        return f.string(from: NSDecimalNumber(string: amount)) ?? "\(currency) \(amount)"
    }

    // MARK: saving

    private func addEvent(_ e: Event) {
        let store = EKEventStore()
        store.requestWriteOnlyAccessToEvents { ok, _ in
            guard ok else { Task { @MainActor in saved = "Calendar access was not allowed (Settings › PrivateEdge)." }; return }
            let ev = EKEvent(eventStore: store)
            ev.title = e.title.capitalizedFirst
            ev.startDate = date(e.start)
            ev.endDate = date(e.start).addingTimeInterval(TimeInterval(e.durationMin * 60))
            ev.calendar = store.defaultCalendarForNewEvents
            let msg = (try? store.save(ev, span: .thisEvent)) != nil ? "Added to your calendar." : "Could not save the event."
            Task { @MainActor in saved = msg }
        }
    }

    private func addReminder(_ r: Reminder) {
        let store = EKEventStore()
        store.requestFullAccessToReminders { ok, _ in
            guard ok else { Task { @MainActor in saved = "Reminders access was not allowed (Settings › PrivateEdge)." }; return }
            let rem = EKReminder(eventStore: store)
            rem.title = r.title.capitalizedFirst
            rem.calendar = store.defaultCalendarForNewReminders()
            let d = date(r.start)
            rem.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: d)
            rem.addAlarm(EKAlarm(absoluteDate: d))
            let msg = (try? store.save(rem, commit: true)) != nil ? "Added to Reminders." : "Could not save the reminder."
            Task { @MainActor in saved = msg }
        }
    }
}

extension String {
    /// "dinner with Sam" -> "Dinner with Sam" (display only; the stored title is unchanged).
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
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

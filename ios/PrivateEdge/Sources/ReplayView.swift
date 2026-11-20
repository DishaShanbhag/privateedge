import CalendarCore
import SwiftUI

/// Runs the 60 dev items through one config on the phone and writes the same _pred.jsonl and
/// _trajectory.jsonl files as harness/run_calendar.py, plus device fields. Share them to the Mac
/// and score with eval/score_calendar.py.
struct ReplayView: View {
    @EnvironmentObject var app: AppModel
    @State private var config: LadderConfig = .C3
    @State private var pauseS = 0
    @State private var running = false
    @State private var stopRequested = false
    @State private var done = 0
    @State private var log: [String] = []
    @State private var totals: [Double] = []
    @State private var firsts: [Double] = []
    @State private var peakMB = 0.0
    @State private var thermal = thermalName(ProcessInfo.processInfo.thermalState)
    @State private var files: [URL] = []
    @State private var error: String?

    private let items = Resources.devItems

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Config", selection: $config) {
                        ForEach(LadderConfig.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Pause between messages", selection: $pauseS) {
                        Text("none").tag(0)
                        Text("20 s (sustained-use test)").tag(20)
                    }
                    Button(running ? "Stop after this message" : "Run all \(items.count) dev messages") {
                        if running { stopRequested = true } else { start() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!ready)
                } footer: {
                    Text("Keep the app open; the screen stays on during a run. For the measurement protocol: release build, airplane mode, Low Power Mode off, unplugged.")
                }

                if running || done > 0 {
                    Section("Progress") {
                        ProgressView(value: Double(done), total: Double(items.count)) { Text("\(done) / \(items.count)") }
                        stat("Total time median / p95", pct(totals))
                        stat("First token median / p95", pct(firsts))
                        stat("Peak memory", String(format: "%.0f MB", peakMB))
                        stat("Thermal state", thermal)
                    }
                    Section("Messages") {
                        ForEach(log.suffix(8).reversed(), id: \.self) { Text($0).font(.system(.caption, design: .monospaced)) }
                    }
                }
                if !files.isEmpty {
                    Section("Results (AirDrop or save to Files, then score on the Mac)") {
                        ForEach(files, id: \.self) { f in ShareLink(item: f) { Label(f.lastPathComponent, systemImage: "square.and.arrow.up") } }
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle("Replay dev set")
        }
    }

    private var ready: Bool { if case .ready = app.state { return true }; return false }

    private func stat(_ k: String, _ v: String) -> some View {
        HStack { Text(k).foregroundStyle(.secondary); Spacer(); Text(v) }.font(.footnote)
    }

    private func pct(_ xs: [Double]) -> String {
        guard !xs.isEmpty else { return "-" }
        let s = xs.sorted()
        func p(_ q: Double) -> Double { s[min(s.count - 1, max(0, Int((q / 100 * Double(s.count - 1)).rounded())))] }
        return String(format: "%.2f / %.2f s", p(50) / 1000, p(95) / 1000)
    }

    private func start() {
        running = true; stopRequested = false; done = 0; log = []; totals = []; firsts = []; peakMB = 0; files = []; error = nil
        UIApplication.shared.isIdleTimerDisabled = true
        let cfg = config, pause = pauseS
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("results")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = "\(cfg.rawValue)_calendar_dev_phone_\(deviceModel())_\(stamp)"
        let predURL = dir.appendingPathComponent(base + "_pred.jsonl")
        let trajURL = dir.appendingPathComponent(base + "_trajectory.jsonl")
        Task {
            var preds = "", traj = ""
            for (n, it) in items.enumerated() {
                if stopRequested { break }
                if n > 0 && pause > 0 { try? await Task.sleep(for: .seconds(pause)) }
                do {
                    // "Today Date" = the item's reference date, as the Mac runner (chat_prompt.py)
                    let r = try await app.service.run(it, cfg, today: templateDate(it))
                    preds += dumpJSON(.obj(r.predRow())) + "\n"
                    traj += dumpJSON(.obj(r.trajectoryRow(backend: BACKEND_NAME))) + "\n"
                    // Write after every item so a stopped run keeps what it did.
                    try preds.write(to: predURL, atomically: true, encoding: .utf8)
                    try traj.write(to: trajURL, atomically: true, encoding: .utf8)
                    done = n + 1
                    totals.append(r.info.totalMs)
                    if let f = r.info.firstTokenMs { firsts.append(f) }
                    peakMB = max(peakMB, num(r.device.json["peak_footprint_mb"]) ?? 0)
                    thermal = r.device.json["thermal_state_after"]?.asString ?? "?"
                    log.append(String(format: "%@ %-7@ %5.2fs", it.id, r.decision as NSString, r.info.totalMs / 1000))
                } catch {
                    self.error = "\(it.id): \(error.localizedDescription)"
                    break
                }
            }
            files = [predURL, trajURL].filter { FileManager.default.fileExists(atPath: $0.path) }
            running = false
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }
}

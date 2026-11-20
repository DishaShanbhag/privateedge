import Foundation
import PrivateEdgeCore
import SwiftUI
import UIKit

// The measurement runs from the proposal (formerly Yash's ios/App RunController, on PrivateEdgeCore's
// ReplayRunner), inside this app. Output: Documents/runs/<time>_<name>/ with pred.jsonl,
// trajectory.jsonl, memory.csv (every 50 ms) and summary.json.

enum MeasureMode: String, CaseIterable, Identifiable {
    case gate = "Feasibility gate (10 notes + 10 calendar)"
    case full = "Full dev run (one config)"
    case sustained = "Sustained: 30 requests, one per 20 s"
    case stress = "Stress: 10 minutes back-to-back"
    var id: String { rawValue }
}

@MainActor
final class MeasureController: ObservableObject {
    @Published var log: [String] = []
    @Published var running = false
    @Published var thermal = DeviceMetrics.thermalState()
    @Published var footprintMB = 0.0
    @Published var availableMB: Double?
    @Published var battery: Float = -1
    @Published var runs: [String] = []
    @Published var problem: String?
    private var stopRequested = false
    private var manifest: Manifest?
    private var ticker: Timer?
    let bundleDir = Bundle.main.url(forResource: "Bundle", withExtension: nil)

    init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        if let b = bundleDir, let m = try? JSONDecoder().decode(Manifest.self, from: Data(contentsOf: b.appendingPathComponent("manifest.json"))) {
            manifest = m
            runs = m.runs.map(\.name)
        } else {
            problem = "Run bundle missing: python harness/export_ios_bundle.py, then ios/scripts/make_project.sh"
        }
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        thermal = DeviceMetrics.thermalState()
        footprintMB = Double(DeviceMetrics.footprintBytes()) / 1_048_576
        availableMB = DeviceMetrics.availableBytes().map { Double($0) / 1_048_576 }
        battery = UIDevice.current.batteryLevel
    }

    func append(_ s: String) {
        log.append(s)
        if log.count > 400 { log.removeFirst(log.count - 400) }
    }

    func stop() { stopRequested = true }

    func start(mode: MeasureMode, runName: String, app: AppModel) {
        guard let manifest, let bundleDir, !running else { return }
        running = true
        stopRequested = false
        UIApplication.shared.isIdleTimerDisabled = true   // screen stays on at fixed brightness
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        Task {
            // One copy of the weights at a time: free the Calendar/Notes model first.
            await app.unload()
            append("Freed the shared model; loading the measurement copy…")
            #if targetEnvironment(simulator)
            append("Simulator: CPU only, about 2-3 min per request. Timings, memory and heat are the Mac's.")
            #endif
            let stopFlag: () -> Bool = { DispatchQueue.main.sync { self.stopRequested } }
            let logFn: (String) -> Void = { s in Task { @MainActor in self.append(s) } }
            await Task.detached(priority: .userInitiated) {
                let battery: () -> Double? = {
                    let b = DispatchQueue.main.sync { UIDevice.current.batteryLevel }
                    return b < 0 ? nil : Double(b)
                }
                do {
                    let runner = try ReplayRunner(bundle: bundleDir, modelDir: try modelDirectory())
                    func spec(_ n: String) -> RunSpec { manifest.runs.first { $0.name == n }! }
                    switch mode {
                    case .gate:
                        // Notes with C2 retrieval (index loaded) and calendar C1; C3 is checked by
                        // CalendarCore on the phone in the Calendar tab, or on the Mac for these files.
                        for (name, task) in [("C2_notes", "notes"), ("C1_calendar", "calendar")] {
                            try runner.run(spec(name), ids: Set(manifest.gate_ids[task] ?? []),
                                           out: Self.out(stamp, "gate_\(name)"), battery: battery, shouldStop: stopFlag, log: logFn)
                        }
                    case .full:
                        try runner.run(spec(runName), out: Self.out(stamp, runName), battery: battery, shouldStop: stopFlag, log: logFn)
                    case .sustained:
                        try runner.run(spec(runName), limit: 30, pacing: Pacing(secondsBetweenStarts: 20),
                                       out: Self.out(stamp, "sustained_\(runName)"), battery: battery, shouldStop: stopFlag, log: logFn)
                    case .stress:
                        try runner.run(spec(runName), pacing: Pacing(durationLimitS: 600),
                                       out: Self.out(stamp, "stress_\(runName)"), battery: battery, shouldStop: stopFlag, log: logFn)
                    }
                    logFn("Done. Results are in Documents/runs (Files app › On My iPhone › PrivateEdge).")
                } catch {
                    logFn("ERROR: \(error)")
                }
                // `runner` goes out of scope here, which frees the measurement copy of the weights.
            }.value
            running = false
            UIApplication.shared.isIdleTimerDisabled = false
            append("Reloading the shared model for the Calendar and Notes tabs.")
            app.load()
        }
    }

    nonisolated static func out(_ stamp: String, _ name: String) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("runs").appendingPathComponent("\(stamp)_\(name)")
    }
}

struct MeasureView: View {
    @EnvironmentObject var app: AppModel
    @StateObject private var c = MeasureController()
    @State private var mode: MeasureMode = .gate
    @State private var runName = "C2_notes"

    var body: some View {
        NavigationStack {
            Form {
                Section("Device") {
                    LabeledContent("Thermal state", value: c.thermal)
                    LabeledContent("Memory footprint", value: String(format: "%.0f MB", c.footprintMB))
                    LabeledContent("Available to app", value: c.availableMB.map { String(format: "%.0f MB", $0) } ?? "–")
                    LabeledContent("Battery", value: c.battery < 0 ? "–" : String(format: "%.0f%%", c.battery * 100))
                }
                if let p = c.problem { Section { Text(p).foregroundStyle(.red) } }
                Section {
                    Picker("Mode", selection: $mode) { ForEach(MeasureMode.allCases) { Text($0.rawValue).tag($0) } }
                    if mode != .gate {
                        Picker("Config", selection: $runName) { ForEach(c.runs, id: \.self) { Text($0).tag($0) } }
                    }
                    if c.running {
                        Button("Stop after this request", role: .destructive) { c.stop() }
                    } else {
                        Button("Start") { c.start(mode: mode, runName: runName, app: app) }.disabled(c.problem != nil)
                    }
                } header: {
                    Text("Run")
                } footer: {
                    Text("Heat: iOS reports a thermal state (nominal, fair, serious, critical), logged before and after every request; the slowdown shows as decode tok/s over the sustained and stress runs. Only a real iPhone gives phone numbers.")
                }
                Section("Log") {
                    ForEach(Array(c.log.suffix(60).enumerated()), id: \.offset) { Text($0.element).font(.caption.monospaced()) }
                }
            }
            .navigationTitle("Measure")
        }
    }
}

import Foundation
import PrivateEdgeCore
import UIKit

/// The measurement runs from the proposal, on top of PrivateEdgeCore's ReplayRunner.
enum Mode: String, CaseIterable, Identifiable {
    case gate = "Feasibility gate (10 notes + 10 calendar)"
    case full = "Full dev run (one config)"
    case sustained = "Sustained: 30 requests, one per 20 s"
    case stress = "Stress: 10 minutes back-to-back"
    var id: String { rawValue }
}

@MainActor
final class RunController: ObservableObject {
    @Published var log: [String] = []
    @Published var running = false
    @Published var thermal = DeviceMetrics.thermalState()
    @Published var footprintMB = 0.0
    @Published var availableMB: Double?
    @Published var battery: Float = -1
    @Published var runs: [String] = []
    @Published var missingFiles: [String] = []
    private var stopRequested = false
    private var runner: ReplayRunner?
    private var ticker: Timer?

    let bundleDir = Bundle.main.resourceURL!.appendingPathComponent("Bundle")
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        do {
            runner = try ReplayRunner(bundle: bundleDir, modelDir: docs)
            runs = runner!.manifest.runs.map(\.name)
            checkFiles()
        } catch {
            append("Cannot read the bundle: \(error)")
        }
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func checkFiles() {
        guard let m = runner?.manifest else { return }
        var need = [m.model_file]
        need += m.runs.compactMap { $0.retrieval?.embedding_file }
        missingFiles = Array(Set(need.filter { !FileManager.default.fileExists(atPath: docs.appendingPathComponent($0).path) })).sorted()
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

    func start(mode: Mode, runName: String) {
        guard let runner, !running else { return }
        checkFiles()
        if !missingFiles.isEmpty { append("Missing in Documents: \(missingFiles.joined(separator: ", "))"); return }
        running = true
        stopRequested = false
        UIApplication.shared.isIdleTimerDisabled = true   // screen stays on at fixed brightness
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let m = runner.manifest
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let log: (String) -> Void = { s in Task { @MainActor in self.append(s) } }
            let battery: () -> Double? = {
                let b = DispatchQueue.main.sync { UIDevice.current.batteryLevel }
                return b < 0 ? nil : Double(b)
            }
            let stop: () -> Bool = { DispatchQueue.main.sync { self.stopRequested } }
            do {
                switch mode {
                case .gate:
                    // Notes with C2 retrieval (index loaded) and calendar C1 (C3 = C1 + verification on the Mac).
                    for (name, task) in [("C2_notes", "notes"), ("C1_calendar", "calendar")] {
                        let spec = m.runs.first { $0.name == name }!
                        try runner.run(spec, ids: Set(m.gate_ids[task] ?? []), out: self.out(stamp, "gate_\(name)"),
                                       battery: battery, shouldStop: stop, log: log)
                    }
                case .full:
                    let spec = m.runs.first { $0.name == runName }!
                    try runner.run(spec, out: self.out(stamp, runName), battery: battery, shouldStop: stop, log: log)
                case .sustained:
                    let spec = m.runs.first { $0.name == runName }!
                    try runner.run(spec, limit: 30, pacing: Pacing(secondsBetweenStarts: 20),
                                   out: self.out(stamp, "sustained_\(runName)"), battery: battery, shouldStop: stop, log: log)
                case .stress:
                    let spec = m.runs.first { $0.name == runName }!
                    try runner.run(spec, pacing: Pacing(durationLimitS: 600),
                                   out: self.out(stamp, "stress_\(runName)"), battery: battery, shouldStop: stop, log: log)
                }
                log("Results are in Documents/runs (Finder > iPhone > Files > PrivateEdge).")
            } catch {
                log("ERROR: \(error)")
            }
            await MainActor.run {
                self.running = false
                UIApplication.shared.isIdleTimerDisabled = false
            }
        }
    }

    nonisolated func out(_ stamp: String, _ name: String) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("runs").appendingPathComponent("\(stamp)_\(name)")
    }
}

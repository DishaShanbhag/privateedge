import SwiftUI

struct ContentView: View {
    @StateObject private var c = RunController()
    @State private var mode: Mode = .gate
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
                if !c.missingFiles.isEmpty {
                    Section("Copy these into the app's Documents (Finder > iPhone > Files)") {
                        ForEach(c.missingFiles, id: \.self) { Text($0).font(.footnote.monospaced()) }
                        Button("Check again") { c.checkFiles() }
                    }
                }
                Section("Run") {
                    Picker("Mode", selection: $mode) { ForEach(Mode.allCases) { Text($0.rawValue).tag($0) } }
                    if mode != .gate {
                        Picker("Config", selection: $runName) { ForEach(c.runs, id: \.self) { Text($0).tag($0) } }
                    }
                    if c.running {
                        Button("Stop after this request", role: .destructive) { c.stop() }
                    } else {
                        Button("Start") { c.start(mode: mode, runName: runName) }.disabled(!c.missingFiles.isEmpty)
                    }
                }
                Section("Log") {
                    ForEach(Array(c.log.suffix(60).enumerated()), id: \.offset) { Text($0.element).font(.caption.monospaced()) }
                }
            }
            .navigationTitle("PrivateEdge")
        }
    }
}

import SwiftUI
import os

struct ModelView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
            Form {
                Section("Model") {
                    row("File", MODEL_FILE)
                    row("Size", app.modelSizeGB)
                    row("Runtime", LLAMA_CPP)
                    #if targetEnvironment(simulator)
                    row("Compute", app.useGPU ? "Mac GPU via the Simulator (not phone numbers)" : "Mac CPU (slow; not phone numbers)")
                    #else
                    row("Compute", app.useGPU ? "Metal GPU, all layers" : "CPU only")
                    #endif
                    Toggle("Use the GPU (Metal)", isOn: $app.useGPU)
                    ModelStatusLine()
                    Toggle("Memory-map the weights (mmap)", isOn: $app.useMmap)
                    Button("Load / reload model") { app.load() }
                }
                Section("Integrity") {
                    row("SHA-256", app.shaState)
                    Button("Check against the pinned SHA-256") { app.checkSHA() }
                }
                Section("Device") {
                    row("Model", deviceModel())
                    row("iOS", ProcessInfo.processInfo.operatingSystemVersionString)
                    row("App memory now", String(format: "%.0f MB", mb(footprintBytes())))
                    row("Memory still available", String(format: "%.0f MB", mb(UInt64(os_proc_available_memory()))))
                    row("Thermal state", thermalName(ProcessInfo.processInfo.thermalState))
                }
                if app.modelPath == nil {
                    Section("Model file missing") {
                        Text("Put \(MODEL_FILE) in the repo's models/ folder and rebuild, or copy it into this app's folder with the Files app (On My iPhone › PrivateEdge) or Finder, then tap Load.")
                    }
                }
            }
            .navigationTitle("Model")
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) { Text(k).foregroundStyle(.secondary); Spacer(); Text(v).multilineTextAlignment(.trailing) }
            .font(.footnote)
    }
}

import SwiftUI

/// Research tools, kept out of the everyday screens: dev-set replay, device measurements, model info.
struct LabView: View {
    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink { ReplayView() } label: {
                        row("Replay the dev set", "Run all 60 calendar dev messages and export the results", "list.bullet.rectangle", .blue)
                    }
                    NavigationLink { MeasureView() } label: {
                        row("Measurements", "Feasibility gate, sustained and stress runs: speed, memory, heat, battery", "thermometer.medium", .orange)
                    }
                    NavigationLink { ModelView() } label: {
                        row("Model and device", "Load the model, check its fingerprint, memory and thermal state", "cpu", .gray)
                    }
                } footer: {
                    Text("These tools are for the PrivateEdge study. Results are saved in the app's Documents folder.")
                }
            }
            .navigationTitle("Lab")
        }
    }

    private func row(_ title: String, _ sub: String, _ icon: String, _ color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(.white).frame(width: 32, height: 32)
                .background(color, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(sub).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

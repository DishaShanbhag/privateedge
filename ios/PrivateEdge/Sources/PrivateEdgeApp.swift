import SwiftUI

@main
struct PrivateEdgeApp: App {
    @StateObject private var app = AppModel()
    // Launch argument `-tab notes` / `-tab lab` opens that tab (screenshots and checks).
    @State private var tab = demoArgument("-tab") ?? "calendar"

    var body: some Scene {
        WindowGroup {
            TabView(selection: $tab) {
                CalendarView().tabItem { Label("Calendar", systemImage: "calendar") }.tag("calendar")
                NotesView().tabItem { Label("Notes", systemImage: "note.text") }.tag("notes")
                LabView().tabItem { Label("Lab", systemImage: "flask") }.tag("lab")
            }
            .environmentObject(app)
            .task { app.load() }
        }
    }
}

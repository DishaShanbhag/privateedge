import SwiftUI

@main
struct PrivateEdgeApp: App {
    @StateObject private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            TabView {
                CalendarView().tabItem { Label("Calendar", systemImage: "calendar") }
                ReplayView().tabItem { Label("Replay", systemImage: "list.bullet.rectangle") }
                ModelView().tabItem { Label("Model", systemImage: "cpu") }
            }
            .environmentObject(app)
            .task { app.load() }
        }
    }
}

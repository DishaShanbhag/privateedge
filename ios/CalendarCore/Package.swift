// swift-tools-version:5.9
// CalendarCore: the calendar/actions logic of PrivateEdge in Swift, for the iPhone app.
// A port of harness/resolver.py, harness/calendar_schema.py, harness/verify_calendar.py and the
// title rule of eval/score_calendar.py. `swift run calcore-parity` checks it against the Python
// on every dev item and every saved model output (Fixtures/parity.jsonl, made by
// harness/export_swift_parity.py).
import PackageDescription

let package = Package(
    name: "CalendarCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "CalendarCore", targets: ["CalendarCore"])],
    targets: [
        .target(name: "CalendarCore"),
        .executableTarget(name: "calcore-parity", dependencies: ["CalendarCore"]),
    ]
)

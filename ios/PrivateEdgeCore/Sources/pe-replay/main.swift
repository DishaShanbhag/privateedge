// pe-replay: run an exported configuration on the Mac with the Swift pipeline, to check that it
// matches the Python harness before it goes to the phone.
//
//   swift run -c release pe-replay --bundle ../App/Bundle --models ../../models --run C1_notes --out OUT [--limit N] [--gate]
import Foundation
import PrivateEdgeCore

var args = [String: String]()
var flags = Set<String>()
var it = CommandLine.arguments.dropFirst().makeIterator()
while let a = it.next() {
    if a == "--gate" { flags.insert(a); continue }
    guard a.hasPrefix("--"), let v = it.next() else { FileHandle.standardError.write(Data("bad argument \(a)\n".utf8)); exit(2) }
    args[String(a.dropFirst(2))] = v
}
guard let bundle = args["bundle"], let models = args["models"], let runName = args["run"], let out = args["out"] else {
    print("usage: pe-replay --bundle DIR --models DIR --run NAME --out DIR [--limit N] [--gate]")
    exit(2)
}
do {
    let runner = try ReplayRunner(bundle: URL(fileURLWithPath: bundle), modelDir: URL(fileURLWithPath: models))
    guard let spec = runner.manifest.runs.first(where: { $0.name == runName }) else {
        print("no run named \(runName); available: \(runner.manifest.runs.map(\.name))"); exit(2)
    }
    let ids = flags.contains("--gate") ? runner.manifest.gate_ids[spec.task].map(Set.init) : nil
    try runner.run(spec, ids: ids, limit: args["limit"].flatMap(Int.init), out: URL(fileURLWithPath: out)) { print($0) }
} catch {
    print("error: \(error)"); exit(1)
}

import CalendarCore
import Foundation
import UIKit
import os

// Device measurements from the protocol in docs/milestone2: memory sampled every 50 ms, the
// per-app limit from os_proc_available_memory, thermal state per request, battery.

func footprintBytes() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? info.phys_footprint : 0
}

func mb(_ b: UInt64) -> Double { (Double(b) / 1_048_576 * 10).rounded() / 10 }

func thermalName(_ s: ProcessInfo.ThermalState) -> String {
    switch s {
    case .nominal: return "nominal"
    case .fair: return "fair"
    case .serious: return "serious"
    case .critical: return "critical"
    @unknown default: return "unknown"
    }
}

func deviceModel() -> String {
    var u = utsname()
    uname(&u)
    return withUnsafeBytes(of: &u.machine) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
}

struct DeviceSnapshot {
    var json = JObj()

    static func now() -> DeviceSnapshot {
        let battery: Float = MainThread.sync {
            UIDevice.current.isBatteryMonitoringEnabled = true
            return UIDevice.current.batteryLevel
        }
        return DeviceSnapshot(json: JObj([
            ("thermal_state", .str(thermalName(ProcessInfo.processInfo.thermalState))),
            ("footprint_mb", .float(mb(footprintBytes()))),
            ("available_mb", .float(mb(UInt64(os_proc_available_memory())))),
            ("battery_level", battery < 0 ? .null : .float(Double(battery))),
            ("low_power_mode", .bool(ProcessInfo.processInfo.isLowPowerModeEnabled)),
        ]))
    }

    /// Before/after pair plus the 50 ms peak, flattened for the trajectory file.
    func merged(after: DeviceSnapshot, peakMB: Double) -> DeviceSnapshot {
        var j = JObj()
        j["device_model"] = .str(deviceModel())
        j["os_version"] = .str(ProcessInfo.processInfo.operatingSystemVersionString)
        for k in json.keys { j[k + "_before"] = json[k]! }
        for k in after.json.keys where k != "low_power_mode" { j[k + "_after"] = after.json[k]! }
        j["peak_footprint_mb"] = .float(peakMB)
        return DeviceSnapshot(json: j)
    }
}

enum MainThread {
    static func sync<T>(_ f: () -> T) -> T { Thread.isMainThread ? f() : DispatchQueue.main.sync(execute: f) }
}

/// Samples the app's physical footprint every 50 ms between start() and stop().
final class MemorySampler {
    private var timer: DispatchSourceTimer?
    private var peak: UInt64 = 0
    private let q = DispatchQueue(label: "memory-sampler")

    func start() {
        q.sync { peak = footprintBytes() }
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now(), repeating: .milliseconds(50))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.peak = max(self.peak, footprintBytes())
        }
        t.resume()
        timer = t
    }

    /// Stops sampling and returns the peak in MB.
    func stop() -> Double {
        timer?.cancel()
        timer = nil
        return q.sync { mb(max(peak, footprintBytes())) }
    }
}

extension JObj {
    mutating func merge(_ o: JObj) { for k in o.keys { self[k] = o[k]! } }
}

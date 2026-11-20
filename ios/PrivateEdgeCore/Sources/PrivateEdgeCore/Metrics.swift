import Foundation
#if os(iOS)
import os
#endif

/// Device measurements. iOS gives apps no temperature, only ProcessInfo.thermalState
/// (nominal, fair, serious, critical), so heat is logged as that level plus its effect on speed.
public enum DeviceMetrics {
    /// The app's memory footprint (what iOS counts against the per-app limit), in bytes.
    public static func footprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : 0
    }

    /// Memory the app can still allocate before iOS terminates it (iOS only).
    public static func availableBytes() -> UInt64? {
        #if os(iOS)
        return UInt64(os_proc_available_memory())
        #else
        return nil
        #endif
    }

    public static func thermalState() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}

/// Samples the memory footprint every 50 ms (the protocol's rate) and keeps the peak and the
/// lowest available memory. `mark()` starts a new per-request window; the run-wide peak is kept.
public final class MemorySampler {
    private let queue = DispatchQueue(label: "pe.memory", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var windowPeak: UInt64 = 0, runPeak: UInt64 = 0
    private var windowMinAvail: UInt64 = .max, runMinAvail: UInt64 = .max
    public private(set) var samples: [(t: Double, footprint: UInt64, available: UInt64?)] = []
    private let t0 = Date()

    public init() {}

    public func start(intervalMs: Int = 50) {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(intervalMs))
        t.setEventHandler { [weak self] in self?.sample() }
        timer = t
        t.resume()
    }

    public func stop() { timer?.cancel(); timer = nil }

    private func sample() {
        let f = DeviceMetrics.footprintBytes(), a = DeviceMetrics.availableBytes()
        windowPeak = max(windowPeak, f); runPeak = max(runPeak, f)
        if let a { windowMinAvail = min(windowMinAvail, a); runMinAvail = min(runMinAvail, a) }
        samples.append((Date().timeIntervalSince(t0), f, a))
    }

    /// Returns the window's (peak footprint MB, min available MB) and starts a new window.
    public func mark() -> (Double, Double?) {
        queue.sync {
            sample()
            let r = (Double(windowPeak) / 1_048_576, windowMinAvail == .max ? nil : Double(windowMinAvail) / 1_048_576)
            windowPeak = 0; windowMinAvail = .max
            return r
        }
    }

    public var runPeakMB: Double { queue.sync { Double(runPeak) / 1_048_576 } }
    public var runMinAvailableMB: Double? { queue.sync { runMinAvail == .max ? nil : Double(runMinAvail) / 1_048_576 } }

    public func csv() -> String {
        queue.sync {
            "t_s,footprint_mb,available_mb\n" + samples.map {
                String(format: "%.3f,%.1f,%@", $0.t, Double($0.footprint) / 1_048_576,
                       $0.available.map { String(format: "%.1f", Double($0) / 1_048_576) } ?? "")
            }.joined(separator: "\n")
        }
    }
}

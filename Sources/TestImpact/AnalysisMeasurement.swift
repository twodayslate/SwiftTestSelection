// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Progress-only measurements for the analyzer process (not compiler children).
struct AnalysisMeasurement {
    private let start = ContinuousClock.now

    func report(_ phase: String) -> String {
        let duration = start.duration(to: .now).components
        let seconds = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
        var result = "\(phase): \(String(format: "%.2f", seconds)) s"
        #if canImport(Darwin)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        if status == KERN_SUCCESS {
            result += String(format: "; analyzer footprint %.1f MiB, process peak %.1f MiB",
                             Double(info.phys_footprint) / 1_048_576,
                             Double(info.ledger_phys_footprint_peak) / 1_048_576)
        }
        #endif
        return result
    }
}

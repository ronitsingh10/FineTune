// FineTune/Utilities/ProcessNameLookup.swift
import Darwin
import Foundation

/// Resolves a PID to its `p_comm` short executable name via sysctl.
enum ProcessNameLookup {
    /// Returns the short executable name for a PID, or nil when the PID is
    /// invalid or the lookup fails.
    static func name(for pid: pid_t) -> String? {
        guard pid > 0 else { return nil }

        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]

        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else {
            return nil
        }

        // `sysctl` zeroes `size` when the PID is not found.
        guard size > 0 else { return nil }

        let name = withUnsafePointer(to: &info.kp_proc.p_comm) { tuplePtr -> String in
            tuplePtr.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: tuplePtr.pointee)) { cStr in
                String(cString: cStr)
            }
        }

        return name.isEmpty ? nil : name
    }
}

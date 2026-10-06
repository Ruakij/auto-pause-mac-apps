import Foundation
import Darwin

/// System-wide memory breakdown, computed the same way Activity Monitor derives its numbers.
struct SystemStats {
    var totalBytes: UInt64
    var appBytes: UInt64
    var wiredBytes: UInt64
    var compressedBytes: UInt64
    var freeBytes: UInt64
    var swapUsedBytes: UInt64
    var swapTotalBytes: UInt64
    /// macOS memory pressure, `kern.memorystatus_vm_pressure_level`; nil if unreadable.
    var pressureLevel: PressureLevel? = nil

    enum PressureLevel: Int32 {
        case normal = 1, warning = 2, critical = 4
    }

    var usedBytes: UInt64 { appBytes + wiredBytes + compressedBytes }
    var usedFraction: Double {
        totalBytes == 0 ? 0 : Double(usedBytes) / Double(totalBytes)
    }

    static func current() -> SystemStats {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        let pageSize = UInt64(vm_kernel_page_size)
        guard kr == KERN_SUCCESS else {
            return SystemStats(totalBytes: UInt64(ProcessInfo.processInfo.physicalMemory),
                                appBytes: 0, wiredBytes: 0, compressedBytes: 0, freeBytes: 0,
                                swapUsedBytes: 0, swapTotalBytes: 0, pressureLevel: readPressureLevel())
        }

        let app = (UInt64(stats.internal_page_count) - UInt64(stats.purgeable_count)) * pageSize
        let wired = UInt64(stats.wire_count) * pageSize
        let compressed = UInt64(stats.compressor_page_count) * pageSize
        let free = UInt64(stats.free_count) * pageSize

        var swapUsage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swapUsage, &size, nil, 0)

        return SystemStats(
            totalBytes: UInt64(ProcessInfo.processInfo.physicalMemory),
            appBytes: app,
            wiredBytes: wired,
            compressedBytes: compressed,
            freeBytes: free,
            swapUsedBytes: UInt64(swapUsage.xsu_used),
            swapTotalBytes: UInt64(swapUsage.xsu_total),
            pressureLevel: readPressureLevel()
        )
    }

    private static func readPressureLevel() -> PressureLevel? {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return nil }
        return PressureLevel(rawValue: level)
    }
}

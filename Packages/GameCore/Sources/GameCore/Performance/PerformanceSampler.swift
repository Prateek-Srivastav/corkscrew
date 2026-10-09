import Darwin
import Foundation
import IOKit

public struct PerformanceSample: Sendable, Equatable {
    /// CPU used by the bottle's processes, Activity Monitor style: 100 = one full core.
    public var cpuPercent: Double
    /// Memory footprint of the bottle's processes (what Activity Monitor calls "Memory").
    public var memoryBytes: UInt64
    public var processCount: Int
    /// Whole-GPU load; macOS doesn't report it per process.
    public var gpuPercent: Int?
    /// Memory the GPU driver has in use, system-wide.
    public var gpuMemoryBytes: UInt64?
    /// Activity Monitor's "Memory Used" (app + wired + compressed), and installed RAM.
    public var systemMemoryUsed: UInt64
    public var systemMemoryTotal: UInt64
}

/// Samples CPU, memory and GPU use for one bottle's Wine processes.
public final class PerformanceSampler {
    private let prefix: String
    private var lastCPUTime: [pid_t: UInt64] = [:]
    private var lastSampleTime: UInt64 = 0
    private var pids: [pid_t] = []
    private var lastScan: UInt64 = 0
    private let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// `prefix` is the bottle's WINEPREFIX as passed to Wine.
    public init(prefix: URL) {
        self.prefix = prefix.standardizedFileURL.path
    }

    public func sample() -> PerformanceSample {
        let now = mach_absolute_time()
        if pids.isEmpty || nanoseconds(now - lastScan) > 3_000_000_000 {
            pids = BottleProcesses.list(prefix: URL(fileURLWithPath: prefix)).map(\.pid)
            lastScan = now
        }

        var cpuTime: [pid_t: UInt64] = [:]
        var memory: UInt64 = 0
        for pid in pids {
            var task = proc_taskinfo()
            let size = Int32(MemoryLayout<proc_taskinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, size) == size else { continue }
            // Task times are in Mach ticks on Apple silicon.
            cpuTime[pid] = nanoseconds(task.pti_total_user + task.pti_total_system)
            memory += Self.footprint(of: pid) ?? task.pti_resident_size
        }

        var cpuPercent = 0.0
        if lastSampleTime != 0 {
            let elapsed = Double(nanoseconds(now - lastSampleTime))
            let used = cpuTime.reduce(UInt64(0)) { total, entry in
                total + entry.value &- min(entry.value, lastCPUTime[entry.key] ?? entry.value)
            }
            if elapsed > 0 { cpuPercent = Double(used) / elapsed * 100 }
        }
        lastCPUTime = cpuTime
        lastSampleTime = now
        pids = Array(cpuTime.keys)   // drop processes that exited

        let gpu = Self.gpuStatistics()
        let system = Self.systemMemory()
        return PerformanceSample(
            cpuPercent: cpuPercent, memoryBytes: memory, processCount: cpuTime.count,
            gpuPercent: gpu.utilization, gpuMemoryBytes: gpu.memory,
            systemMemoryUsed: system.used, systemMemoryTotal: system.total
        )
    }

    private func nanoseconds(_ ticks: UInt64) -> UInt64 {
        ticks * UInt64(timebase.numer) / UInt64(timebase.denom)
    }

    private static func footprint(of pid: pid_t) -> UInt64? {
        var usage = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return status == 0 ? usage.ri_phys_footprint : nil
    }

    private static func gpuStatistics() -> (utilization: Int?, memory: UInt64?) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"))
        guard service != 0 else { return (nil, nil) }
        defer { IOObjectRelease(service) }
        guard let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [String: Any] else { return (nil, nil) }
        return ((stats["Device Utilization %"] as? NSNumber)?.intValue,
                (stats["In use system memory"] as? NSNumber)?.uint64Value)
    }

    private static func systemMemory() -> (used: UInt64, total: UInt64) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        let total = ProcessInfo.processInfo.physicalMemory
        guard status == KERN_SUCCESS else { return (0, total) }
        let page = UInt64(getpagesize())
        let app = UInt64(stats.internal_page_count) - min(UInt64(stats.purgeable_count), UInt64(stats.internal_page_count))
        return ((app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page, total)
    }
}

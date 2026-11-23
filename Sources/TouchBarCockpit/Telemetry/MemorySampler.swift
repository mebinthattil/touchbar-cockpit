import Foundation
import Darwin

final class MemorySampler {
    let totalBytes: Double = Double(ProcessInfo.processInfo.physicalMemory)

    struct Sample {
        let usedGB: Double
        let totalGB: Double
        let appGB: Double
        let wiredGB: Double
        let compressedGB: Double
        let cachedGB: Double
        let activeFrac: Double
        let wiredFrac: Double
        let compressedFrac: Double
        let swapUsedGB: Double
        let swapTotalGB: Double
    }

    func sample() -> Sample {
        var vmStats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &vmStats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }

        let pageSize = Double(vm_kernel_page_size)
        let totalGB = totalBytes / 1_073_741_824.0

        var activeBytes = 0.0
        var wiredBytes = 0.0
        var compressedBytes = 0.0
        var cachedBytes = 0.0
        var usedBytes = 0.0

        if kr == KERN_SUCCESS {
            let internalPages = Double(vmStats.internal_page_count)
            let purgeablePages = Double(vmStats.purgeable_count)
            let externalPages = Double(vmStats.external_page_count)
            let wiredPages = Double(vmStats.wire_count)
            let compressedPages = Double(vmStats.compressor_page_count)

            // Activity Monitor formula: App Memory (internal - purgeable) + Wired + Compressed
            let appPages = max(0, internalPages - purgeablePages)
            activeBytes = appPages * pageSize
            wiredBytes = wiredPages * pageSize
            compressedBytes = compressedPages * pageSize
            cachedBytes = (externalPages + purgeablePages) * pageSize
            usedBytes = activeBytes + wiredBytes + compressedBytes
        }

        var swapUsage = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        var swapUsedGB = 0.0
        var swapTotalGB = 0.0
        if sysctlbyname("vm.swapusage", &swapUsage, &swapSize, nil, 0) == 0 {
            swapUsedGB = Double(swapUsage.xsu_used) / 1_073_741_824.0
            swapTotalGB = Double(swapUsage.xsu_total) / 1_073_741_824.0
        }

        return Sample(
            usedGB: usedBytes / 1_073_741_824.0,
            totalGB: totalGB,
            appGB: activeBytes / 1_073_741_824.0,
            wiredGB: wiredBytes / 1_073_741_824.0,
            compressedGB: compressedBytes / 1_073_741_824.0,
            cachedGB: cachedBytes / 1_073_741_824.0,
            activeFrac: min(1.0, activeBytes / totalBytes),
            wiredFrac: min(1.0, wiredBytes / totalBytes),
            compressedFrac: min(1.0, compressedBytes / totalBytes),
            swapUsedGB: swapUsedGB,
            swapTotalGB: swapTotalGB
        )
    }

    static func fetchTopRAMProcesses(limit: Int = 3) -> [(name: String, mb: Double)] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-Aceo", "rss,comm", "-m"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            guard let text = String(data: data, encoding: .utf8) else { return [] }
            var results: [(String, Double)] = []
            for line in text.split(separator: "\n").dropFirst() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard let spaceIdx = trimmed.firstIndex(where: { $0.isWhitespace }) else { continue }
                let kbStr = String(trimmed[..<spaceIdx])
                let name = String(trimmed[spaceIdx...]).trimmingCharacters(in: .whitespaces)
                if let kb = Double(kbStr), !name.isEmpty {
                    results.append((name, kb / 1024.0))
                    if results.count >= limit { break }
                }
            }
            return results
        } catch {
            return []
        }
    }
}

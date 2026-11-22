import Foundation
import Darwin

final class CPUSampler {
    private var prevTicks: [(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)] = []
    let eCoreCount: Int

    init() {
        var eCores: Int32 = 4
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel1.logicalcpu", &eCores, &size, nil, 0) == 0 && eCores > 0 {
            self.eCoreCount = Int(eCores)
        } else {
            self.eCoreCount = 4
        }
    }

    struct Sample {
        let total: Double
        let user: Double
        let system: Double
        let perCore: [Double]
    }

    func sample() -> Sample {
        var numCPUs: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var numCPUInfo: mach_msg_type_number_t = 0

        let kr = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &numCPUs,
            &cpuInfo,
            &numCPUInfo
        )

        guard kr == KERN_SUCCESS, let info = cpuInfo else {
            return Sample(total: 0, user: 0, system: 0, perCore: [])
        }

        defer {
            let byteSize = vm_size_t(numCPUInfo) * vm_size_t(MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), byteSize)
        }

        let count = Int(numCPUs)
        var current: [(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)] = []
        current.reserveCapacity(count)

        for i in 0..<count {
            let base = Int(CPU_STATE_MAX) * i
            let u = UInt64(bitPattern: Int64(info[base + Int(CPU_STATE_USER)]))
            let s = UInt64(bitPattern: Int64(info[base + Int(CPU_STATE_SYSTEM)]))
            let id = UInt64(bitPattern: Int64(info[base + Int(CPU_STATE_IDLE)]))
            let n = UInt64(bitPattern: Int64(info[base + Int(CPU_STATE_NICE)]))
            current.append((u, s, id, n))
        }

        guard prevTicks.count == count else {
            prevTicks = current
            return Sample(total: 0, user: 0, system: 0, perCore: Array(repeating: 0, count: count))
        }

        var totalUser: UInt64 = 0
        var totalSys: UInt64 = 0
        var totalAll: UInt64 = 0
        var perCore: [Double] = []
        perCore.reserveCapacity(count)

        for i in 0..<count {
            let du = current[i].user &- prevTicks[i].user
            let ds = current[i].system &- prevTicks[i].system
            let di = current[i].idle &- prevTicks[i].idle
            let dn = current[i].nice &- prevTicks[i].nice
            let dTotal = du + ds + di + dn

            totalUser += du + dn
            totalSys += ds
            totalAll += dTotal

            if dTotal > 0 {
                let busy = Double(du + ds + dn) / Double(dTotal) * 100.0
                perCore.append(min(100.0, max(0.0, busy)))
            } else {
                perCore.append(0)
            }
        }

        prevTicks = current

        guard totalAll > 0 else {
            return Sample(total: 0, user: 0, system: 0, perCore: perCore)
        }

        let userPct = Double(totalUser) / Double(totalAll) * 100.0
        let sysPct = Double(totalSys) / Double(totalAll) * 100.0
        let totPct = min(100.0, max(0.0, userPct + sysPct))
        return Sample(total: totPct, user: userPct, system: sysPct, perCore: perCore)
    }

    static func fetchTopProcesses(limit: Int = 3) -> [(name: String, pct: Double)] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-Aceo", "pcpu,comm", "-r"]
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
                let pctStr = String(trimmed[..<spaceIdx])
                let name = String(trimmed[spaceIdx...]).trimmingCharacters(in: .whitespaces)
                if let pct = Double(pctStr), !name.isEmpty {
                    results.append((name, pct))
                    if results.count >= limit { break }
                }
            }
            return results
        } catch {
            return []
        }
    }
}
